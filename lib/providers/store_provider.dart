
import 'package:flutter/material.dart';
import '../models/store.dart';
import '../models/menu_item.dart';
import '../models/order.dart';
import '../models/store_stats.dart';
import '../models/failure.dart';
import '../repositories/menu_repository.dart';
import '../repositories/store_repository.dart';
import '../repositories/order_repository.dart';
import '../constants/static_data.dart';
import '../services/ably_service.dart';
import '../locator.dart';

/// Manages the state of stores, menu items, and owned store operations.
/// 
/// This provider follows a strict repository-provider-UI architecture,
/// ensuring that UI components only interact with this provider and not
/// repositories directly.
class StoreProvider with ChangeNotifier {
  List<Store> _stores = StaticData.stores;
  List<MenuItem> _menuItems = StaticData.menuItems;
  bool _isLoading = false;
  Failure? _failure;

  /// The userId of the current store owner.
  String? _ownerId;

  /// The explicitly set active store ID (useful for workers).
  String? _activeStoreId;

  /// Cached reference to the active/owned store.
  Store? _activeStore;

  /// Returns the list of all available stores.
  List<Store> get stores => _stores;

  /// Returns the list of all menu items across all stores.
  List<MenuItem> get menuItems => _menuItems;

  /// Returns true if an asynchronous operation is in progress.
  bool get isLoading => _isLoading;

  /// Returns the current [Failure] if an operation failed, otherwise null.
  Failure? get failure => _failure;

  /// Convenience getter for error message.
  String? get error => _failure?.message;

  // ─── Centralized Store Context logic ─────────────────────────────

  /// Set the current owner's userId and refreshes the cached [activeStore].
  void setOwner(String userId) {
    _ownerId = userId;
    _activeStoreId = null; // Clear explicit ID if owner is set
    _updateStoreCache();
    notifyListeners();
  }

  /// Explicitly sets the active store ID (e.g., for workers).
  void setActiveStoreId(String storeId) {
    _activeStoreId = storeId;
    _ownerId = null; // Clear owner ID if explicit store is set
    _updateStoreCache();
    notifyListeners();
  }

  /// The store currently in focus (either owned by the user or assigned to them).
  /// 
  /// This getter provides O(1) access via a cached reference.
  Store? get activeStore => _activeStore;

  /// Alias for [activeStore] to maintain backward compatibility with previous refactor.
  Store? get ownedStore => _activeStore;

  /// Convenience getter for the active store's ID.
  String? get activeStoreId => _activeStore?.id;

  /// Alias for [activeStoreId].
  String? get ownedStoreId => _activeStore?.id;

  void _updateStoreCache() {
    if (_activeStoreId != null) {
      try {
        _activeStore = _stores.firstWhere((s) => s.id == _activeStoreId);
        return;
      } catch (_) {
        _activeStore = null;
      }
    }

    if (_ownerId == null || _stores.isEmpty) {
      _activeStore = null;
      return;
    }

    try {
      _activeStore = _stores.firstWhere((s) => s.ownerId == _ownerId);
    } catch (_) {
      _activeStore = null;
    }
  }

  // ─── Lifecycle ───────────────────────────────────────────────────

  StoreProvider() {
    refreshData();
    _initStoreListener();
  }

  void _initStoreListener() {
    locator<AblyService>().addStoreListener(_onStoreUpdate);
  }

  void _onStoreUpdate(String storeId, bool isOpen) {
    final index = _stores.indexWhere((s) => s.id == storeId);
    if (index != -1) {
      _stores[index] = _stores[index].copyWith(isOpen: isOpen);
      if (_stores[index].id == activeStoreId) {
        _activeStore = _stores[index];
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    locator<AblyService>().removeStoreListener(_onStoreUpdate);
    super.dispose();
  }

  // ─── Data Refresh ────────────────────────────────────────────────

  /// Fetches fresh store and menu data from the remote API.
  /// 
  /// Propagates a [Failure] if the network request fails.
  Future<void> refreshData() async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        locator<MenuRepository>().getStores(),
        locator<MenuRepository>().getMenuItems(),
      ]);

      _stores = results[0] as List<Store>;
      _menuItems = results[1] as List<MenuItem>;
      
      _updateStoreCache();
    } catch (e) {
      _failure = Failure('Failed to fetch data from API', originalError: e);
      debugPrint('[StoreProvider] refreshData error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ─── Store Operations (wrapping StoreRepository) ─────────────────

  /// Toggles the owned store's open/closed status.
  Future<void> toggleStoreStatus(bool isOpen) async {
    final id = ownedStoreId;
    if (id == null) return;
    
    _isLoading = true;
    notifyListeners();
    
    try {
      final updated = await locator<StoreRepository>().toggleStoreStatus(id, isOpen);
      final index = _stores.indexWhere((s) => s.id == id);
      if (index != -1) {
        _stores[index] = updated;
        _activeStore = updated;
        notifyListeners();
      }
    } catch (e) {
      _failure = Failure('Failed to update store status', originalError: e);
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Updates the settings for the currently owned store.
  Future<void> updateStore(Map<String, dynamic> data) async {
    final id = ownedStoreId;
    if (id == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      final updated = await locator<StoreRepository>().updateStore(id, data);
      final index = _stores.indexWhere((s) => s.id == id);
      if (index != -1) {
        _stores[index] = updated;
        _activeStore = updated;
        notifyListeners();
      }
    } catch (e) {
      _failure = Failure('Failed to update store settings', originalError: e);
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ─── Order Operations (wrapping OrderRepository) ─────────────────

  /// Fetches real-time statistics for the owned store.
  Future<StoreStats> fetchStoreStats() async {
    final id = ownedStoreId;
    if (id == null) {
      return StoreStats(
        revenue: 0,
        totalOrders: 0,
        pendingOrders: 0,
        preparingOrders: 0,
        topSellingItems: {},
      );
    }
    return locator<OrderRepository>().getStoreStats(id);
  }

  /// Fetches the list of orders belonging to the owned store.
  Future<List<Order>> fetchStoreOrders() async {
    final id = ownedStoreId;
    if (id == null) return [];
    return locator<OrderRepository>().getStoreOrders(id);
  }

  /// Updates an order's status and returns the updated [Order] object.
  Future<Order> updateOrderStatus(String orderId, String status) {
    return locator<OrderRepository>().updateOrderStatus(orderId, status);
  }

  // ─── Menu Operations ─────────────────────────────────────────────

  /// Creates a new menu item for the owned store.
  Future<void> addMenuItem(Map<String, dynamic> data) async {
    try {
      final newItem = await locator<MenuRepository>().createMenuItem(data);
      _menuItems.add(newItem);
      notifyListeners();
    } catch (e) {
      _failure = Failure('Failed to add menu item', originalError: e);
      debugPrint('[StoreProvider] addMenuItem error: $e');
      rethrow;
    }
  }

  /// Updates an existing menu item's details.
  Future<void> updateMenuItem(String id, Map<String, dynamic> data) async {
    try {
      final updated = await locator<MenuRepository>().updateMenuItem(id, data);
      final index = _menuItems.indexWhere((item) => item.id == id);
      if (index != -1) {
        _menuItems[index] = updated;
        notifyListeners();
      }
    } catch (e) {
      _failure = Failure('Failed to update menu item', originalError: e);
      debugPrint('[StoreProvider] updateMenuItem error: $e');
      rethrow;
    }
  }

  /// Deletes a menu item from the store.
  Future<void> deleteMenuItem(String id) async {
    try {
      await locator<MenuRepository>().deleteMenuItem(id);
      _menuItems.removeWhere((item) => item.id == id);
      notifyListeners();
    } catch (e) {
      _failure = Failure('Failed to delete menu item', originalError: e);
      debugPrint('[StoreProvider] deleteMenuItem error: $e');
      rethrow;
    }
  }
}
