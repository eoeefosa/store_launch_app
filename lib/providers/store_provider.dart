import 'package:flutter/material.dart';
import '../models/store.dart';
import '../models/menu_item.dart';
import '../models/order.dart';
import '../models/store_stats.dart';
import '../repositories/menu_repository.dart';
import '../repositories/store_repository.dart';
import '../repositories/order_repository.dart';
import '../constants/static_data.dart';
import '../services/ably_service.dart';

class StoreProvider with ChangeNotifier {
  List<Store> _stores = StaticData.stores;
  List<MenuItem> _menuItems = StaticData.menuItems;
  bool _isLoading = false;
  String? _error;

  /// The userId of the current store owner/worker. Set once via [setOwner].
  String? _ownerId;

  List<Store> get stores => _stores;
  List<MenuItem> get menuItems => _menuItems;
  bool get isLoading => _isLoading;
  String? get error => _error;

  // ─── Centralized "Owned Store" logic ─────────────────────────────

  /// Set the current owner's userId. Call this once after login.
  void setOwner(String userId) {
    _ownerId = userId;
    notifyListeners();
  }

  /// The store owned by the current user. Returns null if not found.
  Store? get ownedStore {
    if (_ownerId == null || _stores.isEmpty) return null;
    try {
      return _stores.firstWhere((s) => s.ownerId == _ownerId);
    } catch (_) {
      return null;
    }
  }

  /// Convenience getter for the owned store's ID.
  String? get ownedStoreId => ownedStore?.id;

  // ─── Lifecycle ───────────────────────────────────────────────────

  StoreProvider() {
    refreshData();
    _initStoreListener();
  }

  void _initStoreListener() {
    ablyService.addStoreListener(_onStoreUpdate);
  }

  void _onStoreUpdate(String storeId, bool isOpen) {
    final index = _stores.indexWhere((s) => s.id == storeId);
    if (index != -1) {
      _stores[index] = _stores[index].copyWith(isOpen: isOpen);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    ablyService.removeStoreListener(_onStoreUpdate);
    super.dispose();
  }

  // ─── Data Refresh ────────────────────────────────────────────────

  Future<void> refreshData() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final fetchedStores = await menuRepository.getStores();
      final fetchedMenu = await menuRepository.getMenuItems();

      if (fetchedStores.isNotEmpty) _stores = fetchedStores;
      if (fetchedMenu.isNotEmpty) _menuItems = fetchedMenu;
    } catch (e) {
      _error = 'Failed to fetch data from API';
      debugPrint('[StoreProvider] refreshData error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ─── Store Operations (wrapping StoreRepository) ─────────────────

  /// Toggle the owned store's open/closed status.
  Future<void> toggleStoreStatus(bool isOpen) async {
    final id = ownedStoreId;
    if (id == null) return;
    final updated = await storeRepository.toggleStoreStatus(id, isOpen);
    final index = _stores.indexWhere((s) => s.id == id);
    if (index != -1) {
      _stores[index] = updated;
      notifyListeners();
    }
  }

  /// Update the owned store's settings.
  Future<void> updateStore(Map<String, dynamic> data) async {
    final id = ownedStoreId;
    if (id == null) return;
    final updated = await storeRepository.updateStore(id, data);
    final index = _stores.indexWhere((s) => s.id == id);
    if (index != -1) {
      _stores[index] = updated;
      notifyListeners();
    }
  }

  // ─── Order Operations (wrapping OrderRepository) ─────────────────

  /// Fetch stats for the owned store.
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
    return orderRepository.getStoreStats(id);
  }

  /// Fetch orders for the owned store.
  Future<List<Order>> fetchStoreOrders() async {
    final id = ownedStoreId;
    if (id == null) return [];
    return orderRepository.getStoreOrders(id);
  }

  /// Update an order's status (via repository) and return the updated order.
  Future<Order> updateOrderStatus(String orderId, String status) {
    return orderRepository.updateOrderStatus(orderId, status);
  }

  // ─── Menu Operations ─────────────────────────────────────────────

  Future<void> addMenuItem(Map<String, dynamic> data) async {
    try {
      final newItem = await menuRepository.createMenuItem(data);
      _menuItems.add(newItem);
      notifyListeners();
    } catch (e) {
      debugPrint('[StoreProvider] addMenuItem error: $e');
    }
  }

  Future<void> updateMenuItem(String id, Map<String, dynamic> data) async {
    try {
      final updated = await menuRepository.updateMenuItem(id, data);
      final index = _menuItems.indexWhere((item) => item.id == id);
      if (index != -1) {
        _menuItems[index] = updated;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[StoreProvider] updateMenuItem error: $e');
    }
  }

  Future<void> deleteMenuItem(String id) async {
    try {
      await menuRepository.deleteMenuItem(id);
      _menuItems.removeWhere((item) => item.id == id);
      notifyListeners();
    } catch (e) {
      debugPrint('[StoreProvider] deleteMenuItem error: $e');
    }
  }
}
