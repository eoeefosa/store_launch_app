import 'dart:async';
import 'package:ably_flutter/ably_flutter.dart' as ably;
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import '../models/order.dart';
import 'notification_service.dart';

/// A focused real-time messaging service backed by Ably.
///
/// Design decisions:
/// - All [StreamSubscription]s are collected in a single [_subscriptions] list
///   and cancelled atomically via [_cancelAllSubscriptions].
/// - Channel subscription logic is split into focused private methods to avoid
///   an [initAbly] god-method.
/// - Uses [debugPrint] instead of bare [print] for release builds.
/// - Prevents duplicate listeners using [_activeSubscriptionKeys].
class AblyService {
  static final AblyService _instance = AblyService._internal();
  factory AblyService() => _instance;
  AblyService._internal();

  ably.Realtime? _realtime;
  bool _isConnecting = false;
  String? _currentUserId;
  Completer<void>? _initCompleter;

  /// All active subscriptions. Cancelled atomically by [_cancelAllSubscriptions].
  final List<StreamSubscription> _subscriptions = [];

  /// Track unique subscription keys (e.g., 'channelName:eventName') to prevent duplicate listeners.
  final Set<String> _activeSubscriptionKeys = {};

  // ── Listener registries ─────────────────────────────────────────────────────

  final List<Function(String orderId, OrderStatus status)> _orderListeners = [];
  final List<Function(String storeId, bool isOpen)> _storeListeners = [];
  final List<Function(String newRole)> _roleListeners = [];
  final List<Function(String storeId)> _approvalListeners = [];
  final List<Function(Map<String, dynamic> payload)> _notificationListeners = [];

  // ── Init ────────────────────────────────────────────────────────────────────

  Future<void> initAbly(String userId) async {
    // If we're already connecting to THIS user, wait for the existing future
    if (_isConnecting && _currentUserId == userId) {
      return _initCompleter?.future;
    }

    // If already connected to this user, just ensure subscriptions are active
    if (_realtime != null && _currentUserId == userId) {
      _subscribeUserChannel(userId);
      _subscribeStoresChannel();
      return;
    }

    // If userId changed, disconnect the old one first
    if (_currentUserId != null && _currentUserId != userId) {
      disconnect();
    }

    _isConnecting = true;
    _currentUserId = userId;
    _initCompleter = Completer<void>();

    try {
      final token = await apiService.storage.read(key: 'launch-fast-token');

      final clientOptions = ably.ClientOptions()
        ..autoConnect = true
        ..authUrl = '${ApiService.baseUrl}/ably/auth'
        ..authHeaders = {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        }
        ..clientId = userId;

      _realtime = ably.Realtime(options: clientOptions);

      _subscriptions.add(
        _realtime!.connection.on().listen((ably.ConnectionStateChange change) {
          if (change.current == ably.ConnectionState.connected) {
            _subscribeUserChannel(userId);
            _subscribeStoresChannel();
            
            try {
              _realtime!.push.activate();
            } catch (e) {
              debugPrint('[AblyService] Error activating push: $e');
            }
          }
        }),
      );
      _initCompleter?.complete();
    } catch (e) {
      _isConnecting = false;
      _currentUserId = null;
      _initCompleter?.completeError(e);
      debugPrint('[AblyService] initAbly failed: $e');
      rethrow;
    } finally {
      _isConnecting = false;
      _initCompleter = null;
    }
  }

  // ── Private channel helpers ─────────────────────────────────────────────────

  void _subscribeUserChannel(String userId) {
    if (_realtime == null) return;

    final channelName = 'user:$userId';
    final channel = _realtime!.channels.get(channelName);

    // 1. Order updates
    _addSafeSubscription(channel, 'order-update', (ably.Message msg) {
      try {
        final data = Map<String, dynamic>.from(msg.data as Map);
        final orderId = data['orderId'] as String;
        final statusStr = data['status'] as String;
        final status = OrderStatusExtension.fromString(statusStr);
        
        notificationService.showNotification(
          title: 'Order Update',
          body: 'Your order is now $statusStr',
        );
        
        for (final cb in _orderListeners) {
          cb(orderId, status);
        }
      } catch (e) {
        debugPrint('[AblyService] order-update parse error: $e');
      }
    });

    // 2. Role updates
    _addSafeSubscription(channel, 'role-update', (ably.Message msg) {
      try {
        final data = Map<String, dynamic>.from(msg.data as Map);
        final newRole = data['newRole'] as String;
        
        notificationService.showNotification(
          title: 'Role Updated',
          body: 'Your account role has been updated to $newRole.',
        );
        
        for (final cb in _roleListeners) {
          cb(newRole);
        }
      } catch (e) {
        debugPrint('[AblyService] role-update parse error: $e');
      }
    });

    // 3. Store approval
    _addSafeSubscription(channel, 'store-approved', (ably.Message msg) {
      try {
        final data = Map<String, dynamic>.from(msg.data as Map);
        final storeId = data['storeId'] as String;
        
        notificationService.showNotification(
          title: 'Store Approved',
          body: 'Your store has been approved and is now active!',
        );
        
        for (final cb in _approvalListeners) {
          cb(storeId);
        }
      } catch (e) {
        debugPrint('[AblyService] store-approved parse error: $e');
      }
    });

    // 4. General notifications
    _addSafeSubscription(channel, 'general-notification', (ably.Message msg) {
      try {
        final data = Map<String, dynamic>.from(msg.data as Map);
        for (final cb in _notificationListeners) {
          cb(data);
        }
      } catch (e) {
        debugPrint('[AblyService] general-notification parse error: $e');
      }
    });
  }

  void _subscribeStoresChannel() {
    if (_realtime == null) return;

    final channel = _realtime!.channels.get('public:stores');
    _addSafeSubscription(channel, 'store-toggle', (ably.Message msg) {
      try {
        final data = Map<String, dynamic>.from(msg.data as Map);
        final storeId = data['storeId'] as String;
        final isOpen = data['isOpen'] as bool;
        for (final cb in _storeListeners) {
          cb(storeId, isOpen);
        }
      } catch (e) {
        debugPrint('[AblyService] store-toggle parse error: $e');
      }
    });
  }

  // ── Public subscription API ─────────────────────────────────────────────────

  void subscribeToRiderChannel(
    String riderId, {
    Function(Map<String, dynamic> data)? onOrderUpdate,
    Function(Map<String, dynamic> data)? onNewJob,
  }) {
    if (_realtime == null) return;

    // Specific Rider Updates
    final riderChannel = _realtime!.channels.get('rider:$riderId');
    _addSafeSubscription(riderChannel, 'order-update', (msg) {
      notificationService.showNotification(
        title: 'Delivery Update',
        body: 'An update is available for your assigned delivery.',
      );
      final data = Map<String, dynamic>.from(msg.data as Map);
      onOrderUpdate?.call(data);
    });

    // Global Available Jobs
    final jobsChannel = _realtime!.channels.get('riders:available');
    _addSafeSubscription(jobsChannel, 'new-job', (msg) {
      notificationService.showNotification(
        title: 'New Delivery Available',
        body: 'A new delivery job is available near you.',
      );
      final data = Map<String, dynamic>.from(msg.data as Map);
      onNewJob?.call(data);
    });
  }

  void subscribeToStoreOrders(String storeId) {
    if (_realtime == null) return;

    final channel = _realtime!.channels.get('store:$storeId:orders');

    // New orders
    _addSafeSubscription(channel, 'new-order', (msg) {
      try {
        final data = Map<String, dynamic>.from(msg.data as Map);
        final orderId = data['id'] as String;
        
        notificationService.showNotification(
          title: 'New Order',
          body: 'You have received a new order!',
        );
        
        for (final cb in _orderListeners) {
          cb(orderId, OrderStatus.pending);
        }
      } catch (e) {
        debugPrint('[AblyService] new-order parse error: $e');
      }
    });

    // Status updates
    _addSafeSubscription(channel, 'order-update', (msg) {
      try {
        final data = Map<String, dynamic>.from(msg.data as Map);
        final orderId = data['orderId'] as String;
        final statusStr = data['status'] as String;
        final status = OrderStatusExtension.fromString(statusStr);

        notificationService.showNotification(
          title: 'Order Status Changed',
          body: 'Order status changed to $statusStr',
        );

        for (final cb in _orderListeners) {
          cb(orderId, status);
        }
      } catch (e) {
        debugPrint('[AblyService] order-update (store) parse error: $e');
      }
    });
  }

  void subscribeToUserOrders(
    String userId,
    Function(String orderId, OrderStatus status) onUpdate,
  ) {
    addOrderListener(onUpdate);
    if (_realtime != null) {
      _subscribeUserChannel(userId);
    }
  }

  // ── Helper ──────────────────────────────────────────────────────────────────

  void _addSafeSubscription(
    ably.RealtimeChannel channel,
    String eventName,
    void Function(ably.Message) onMessage,
  ) {
    final key = '${channel.name}:$eventName';
    if (_activeSubscriptionKeys.contains(key)) return;

    _activeSubscriptionKeys.add(key);
    _subscriptions.add(channel.subscribe(name: eventName).listen(onMessage));
  }

  // ── Listener management ─────────────────────────────────────────────────────

  void addOrderListener(Function(String orderId, OrderStatus status) l) {
    if (!_orderListeners.contains(l)) _orderListeners.add(l);
  }

  void removeOrderListener(Function(String orderId, OrderStatus status) l) =>
      _orderListeners.remove(l);

  void addStoreListener(Function(String storeId, bool isOpen) l) {
    if (!_storeListeners.contains(l)) _storeListeners.add(l);
  }

  void removeStoreListener(Function(String storeId, bool isOpen) l) =>
      _storeListeners.remove(l);

  void addRoleListener(Function(String newRole) l) {
    if (!_roleListeners.contains(l)) _roleListeners.add(l);
  }

  void removeRoleListener(Function(String newRole) l) =>
      _roleListeners.remove(l);

  void addStoreApprovalListener(Function(String storeId) l) {
    if (!_approvalListeners.contains(l)) _approvalListeners.add(l);
  }

  void removeStoreApprovalListener(Function(String storeId) l) =>
      _approvalListeners.remove(l);

  void addNotificationListener(Function(Map<String, dynamic> payload) l) {
    if (!_notificationListeners.contains(l)) _notificationListeners.add(l);
  }

  void removeNotificationListener(Function(Map<String, dynamic> payload) l) =>
      _notificationListeners.remove(l);

  // ── Teardown ────────────────────────────────────────────────────────────────

  /// Cancels every subscription atomically, then closes the Ably connection.
  void disconnect() {
    _cancelAllSubscriptions();
    _realtime?.close();
    _realtime = null;
    _currentUserId = null;
    _orderListeners.clear();
    _storeListeners.clear();
    _roleListeners.clear();
    _approvalListeners.clear();
    _notificationListeners.clear();
    _isConnecting = false;
    debugPrint('[AblyService] Disconnected and listeners cleared.');
  }

  void _cancelAllSubscriptions() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _activeSubscriptionKeys.clear();
  }
}

final ablyService = AblyService();
