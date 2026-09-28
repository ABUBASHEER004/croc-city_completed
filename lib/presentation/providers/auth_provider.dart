import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/app_user.dart';
import '../../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  AuthProvider() {
    _authSubscription = _service.authStateChanges.listen((_) async {
      await loadCurrentUser();
    });
  }

  final AuthService _service = AuthService.instance;

  bool loading = false;
  AppUser? currentUser;
  String? error;
  StreamSubscription<dynamic>? _authSubscription;

  bool get isAuthenticated => _service.currentUser != null;
  bool get isAdmin => currentUser?.isAdmin ?? false;
  bool get isPlayer => currentUser?.isPlayer ?? false;
  bool get isParent => currentUser?.isParent ?? false;
  bool get isPlayerParent => currentUser?.isPlayerParent ?? false;
  bool get isStudentParent => currentUser?.isStudentParent ?? false;
  bool get isStudent => currentUser?.isStudent ?? false;
  bool get isCoach => currentUser?.isCoach ?? false;
  bool get isTeacher => currentUser?.isTeacher ?? false;
  bool get isStaff => currentUser?.isStaff ?? false;

  Future<void> login({
    required String email,
    required String password,
  }) async {
    loading = true;
    error = null;
    notifyListeners();

    try {
      final credential = await _service.login(
        email: email,
        password: password,
      );

      await credential.user?.reload();
      await loadCurrentUser(notify: false, refreshAdminClaim: true);

      if (currentUser == null) {
        await _service.logout();
        throw Exception(
          'Your account profile could not be found. Please contact the academy administrator.',
        );
      }
    } catch (e) {
      error = _cleanError(e);
      rethrow;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> register({
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    required String password,
    required String role,
  }) async {
    loading = true;
    error = null;
    notifyListeners();

    try {
      await _service.register(
        firstName: firstName,
        lastName: lastName,
        email: email,
        phone: phone,
        password: password,
        role: role,
      );
      await loadCurrentUser(notify: false);
    } catch (e) {
      error = _cleanError(e);
      rethrow;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> resetPassword(String email) async {
    await _service.sendPasswordReset(email);
  }

  Future<void> loadCurrentUser({
    bool notify = true,
    bool refreshAdminClaim = false,
  }) async {
    final firebaseUser = _service.currentUser;

    if (firebaseUser == null) {
      currentUser = null;
    } else {
      await firebaseUser.reload();
      final refreshedUser = _service.currentUser;

      if (refreshedUser == null) {
        currentUser = null;
      } else {
        final profile = await _service.getUserProfile(refreshedUser.uid);

        if (profile != null) {
          // Firestore supplies display data. The Firebase custom claim is
          // used only to elevate a verified administrator account.
          final adminClaim = await _service.hasAdminClaim(
            forceRefresh: refreshAdminClaim,
          );

          currentUser = adminClaim && !profile.isAdmin
              ? profile.copyWith(role: 'Administrator')
              : profile;
        } else {
          currentUser = null;
        }
      }
    }

    if (notify) notifyListeners();
  }

  Future<void> refreshCurrentUser() async {
    await _service.reloadUser();
    await loadCurrentUser();
  }

  Future<void> updateProfile({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    final user = currentUser;
    if (user == null) {
      throw Exception('Your session has expired. Please sign in again.');
    }

    await _service.updateProfile(
      uid: user.uid,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
    );
    await refreshCurrentUser();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> logout() async {
    loading = true;
    error = null;
    notifyListeners();

    try {
      // Clear local state immediately so the UI cannot remain stuck on an
      // authenticated dashboard if a provider sign-out call is slow.
      currentUser = null;
      notifyListeners();
      await _service.logout();
    } catch (e) {
      error = _cleanError(e);
      rethrow;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }
}
