import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/app_user.dart';

class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ================= LOGIN =================

  Future<UserCredential> login({
    required String email,
    required String password,
  }) async {
    try {
      var identifier = email.trim();
      if (!identifier.contains('@')) {
        final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('resolveUsername');
        final result = await callable.call({'username': identifier});
        final data = Map<String, dynamic>.from(result.data as Map);
        identifier = data['email']?.toString() ?? '';
        if (identifier.isEmpty) {
          throw Exception('Username could not be resolved. Contact the administrator.');
        }
      }
      return await _auth.signInWithEmailAndPassword(
        email: identifier,
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw Exception(_firebaseError(e));
    }
  }

  // ================= REGISTER =================

  Future<UserCredential> register({
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    required String password,
    required String role,
  }) async {
    try {
      final credential =
          await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      final user = credential.user!;

      await user.updateDisplayName(
        "$firstName $lastName",
      );

      await user.sendEmailVerification();

      final appUser = AppUser(
        uid: user.uid,
        firstName: firstName,
        lastName: lastName,
        email: email.trim(),
        username: email.trim().split('@').first,
        phone: phone,
        role: role,
        emailVerified: false,
        createdAt: DateTime.now(),
      );

      await _firestore
          .collection("users")
          .doc(user.uid)
          .set(appUser.toMap());

      if (role.trim().toLowerCase() == 'coach') {
        await _firestore.collection('coaches').doc(user.uid).set({
          'id': user.uid,
          'firstName': firstName,
          'lastName': lastName,
          'email': email.trim(),
          'phone': phone,
          'specialty': 'Youth Development',
          'licenseNumber': '',
          'experience': '',
          'photoUrl': null,
          'bio': '',
          'active': true,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      return credential;
    } on FirebaseAuthException catch (e) {
      throw Exception(_firebaseError(e));
    }
  }

  // ================= PASSWORD RESET =================

  Future<void> sendPasswordReset(String email) async {
    try {
      var identifier = email.trim();
      if (!identifier.contains('@')) {
        final callable = FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('resolveUsername');
        final result = await callable.call({'username': identifier});
        final data = Map<String, dynamic>.from(result.data as Map);
        identifier = data['email']?.toString() ?? '';
      }
      if (identifier.isEmpty) throw Exception('Username could not be resolved.');
      await _auth.sendPasswordResetEmail(email: identifier);
    } on FirebaseAuthException catch (e) {
      throw Exception(_firebaseError(e));
    }
  }

  // ================= LOGOUT =================

  Future<void> logout() async {
    // Firebase is the source of truth for the app session.
    await _auth.signOut();
  }

  Future<bool> hasAdminClaim({bool forceRefresh = false}) async {
    final user = currentUser;
    if (user == null) return false;

    final token = await user.getIdTokenResult(forceRefresh);
    return token.claims?['admin'] == true ||
        token.claims?['role']?.toString().toLowerCase() == 'admin';
  }

  // ================= RELOAD =================

  Future<void> reloadUser() async {
    final user = currentUser;
    if (user == null) return;

    await user.reload();
    final refreshedUser = _auth.currentUser;

    if (refreshedUser != null) {
      await _firestore.collection('users').doc(refreshedUser.uid).set(
        {'emailVerified': refreshedUser.emailVerified},
        SetOptions(merge: true),
      );
    }
  }

  // ================= PROFILE =================

  Future<AppUser?> getUserProfile(String uid) async {
    final doc = await _firestore
        .collection("users")
        .doc(uid)
        .get();

    if (!doc.exists) {
      return null;
    }

    return AppUser.fromMap(doc.data()!);
  }


  /// Updates the editable profile fields without allowing the account role
  /// or UID to be changed by the client.
  Future<void> updateProfile({
    required String uid,
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    final user = _auth.currentUser;
    if (user == null || user.uid != uid) {
      throw Exception('Your session has expired. Please sign in again.');
    }

    final cleanFirstName = firstName.trim();
    final cleanLastName = lastName.trim();
    final cleanPhone = phone.trim();
    final displayName = '$cleanFirstName $cleanLastName'.trim();

    try {
      await user.updateDisplayName(displayName);
      await _firestore.collection('users').doc(uid).update({
        'firstName': cleanFirstName,
        'lastName': cleanLastName,
        'phone': cleanPhone,
      });
    } on FirebaseException catch (e) {
      throw Exception('Could not save your profile: ${e.message ?? e.code}.');
    }
  }

  // ================= ERROR HANDLER =================

  String _firebaseError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Invalid email address.';

      case 'user-disabled':
        return 'This account has been disabled.';

      case 'user-not-found':
        return 'No account found with this email.';

      case 'wrong-password':
        return 'Incorrect password.';

      case 'email-already-in-use':
        return 'Email address already exists.';

      case 'weak-password':
        return 'Password is too weak.';

      case 'network-request-failed':
        return 'Please check your internet connection.';

      case 'invalid-credential':
        return 'Invalid login credentials.';

      default:
        return e.message ?? 'Authentication failed.';
    }
  }
}