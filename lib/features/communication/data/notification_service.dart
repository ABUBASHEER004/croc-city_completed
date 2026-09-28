import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../firebase_options.dart';
import '../models/notification_model.dart';

const String academyNotificationChannelId = 'academy_updates';
const String academyNotificationChannelName = 'Academy Updates';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}

class NotificationService {
  NotificationService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseMessaging? messaging,
    FlutterLocalNotificationsPlugin? localNotifications,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _messaging = messaging ?? FirebaseMessaging.instance,
        _localNotifications =
            localNotifications ?? FlutterLocalNotificationsPlugin();

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final FirebaseMessaging _messaging;
  final FlutterLocalNotificationsPlugin _localNotifications;

  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<String>? _tokenSubscription;
  bool _initialized = false;

  CollectionReference<Map<String, dynamic>> _notifications(
    String uid,
  ) {
    return _firestore
        .collection('users')
        .doc(uid)
        .collection('notifications');
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandler,
    );

    if (!kIsWeb) {
      await _initializeLocalNotifications();
    }

    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    // Foreground messages are shown through flutter_local_notifications
    // so Android and iOS do not display duplicate alerts.
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    _authSubscription = _auth.authStateChanges().listen(
      (_) => _syncToken(),
    );

    _tokenSubscription = _messaging.onTokenRefresh.listen(
      _saveToken,
    );

    await _syncToken();
  }

  Future<void> _initializeLocalNotifications() async {
    const android = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    const ios = DarwinInitializationSettings();

    const settings = InitializationSettings(
      android: android,
      iOS: ios,
    );

    await _localNotifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse:
          _handleNotificationResponse,
    );

    final androidPlugin =
        _localNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        academyNotificationChannelId,
        academyNotificationChannelName,
        description:
            'Important Croc-City Football Academy notifications.',
        importance: Importance.high,
      ),
    );

    await androidPlugin?.requestNotificationsPermission();
  }

  Future<void> _handleForegroundMessage(
    RemoteMessage message,
  ) async {
    if (kIsWeb) return;

    final title = message.notification?.title ??
        message.data['title']?.toString() ??
        'Croc-City Football Academy';

    final body = message.notification?.body ??
        message.data['message']?.toString() ??
        '';

    if (body.isEmpty) return;

    final id = DateTime.now()
        .millisecondsSinceEpoch
        .remainder(2147483647);

    await _localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          academyNotificationChannelId,
          academyNotificationChannelName,
          channelDescription:
              'Important academy notifications.',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: message.data['notificationId']?.toString(),
    );
  }

  void _handleNotificationResponse(
    NotificationResponse response,
  ) {
    // The notification is already stored in the user's inbox.
    // The app can open the notification route from the inbox.
  }

  Future<void> _syncToken() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final token = await _messaging.getToken();
      if (token == null || token.trim().isEmpty) return;
      await _saveToken(token);
    } catch (error) {
      debugPrint('FCM token sync failed: $error');
    }
  }

  Future<void> _saveToken(String token) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || token.trim().isEmpty) return;

    await _firestore.collection('users').doc(uid).set(
      <String, dynamic>{
        'fcmTokens': FieldValue.arrayUnion(<String>[token]),
        'notificationsEnabled': true,
        'notificationTokenUpdatedAt':
            FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Stream<List<NotificationModel>> watchForCurrentUser() {
    final uid = _auth.currentUser?.uid;

    if (uid == null) {
      return Stream<List<NotificationModel>>.value(
        const <NotificationModel>[],
      );
    }

    return _notifications(uid)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(
                (doc) => NotificationModel.fromMap(
                  doc.id,
                  doc.data(),
                ),
              )
              .toList(),
        );
  }

  Stream<int> watchUnreadCount() {
    return watchForCurrentUser().map(
      (items) => items.where((item) => !item.read).length,
    );
  }

  Future<void> markAsRead(String notificationId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || notificationId.trim().isEmpty) return;

    await _notifications(uid)
        .doc(notificationId)
        .update(<String, dynamic>{
      'read': true,
      'readAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> markAllAsRead() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    final snapshot = await _notifications(uid)
        .where('read', isEqualTo: false)
        .limit(100)
        .get();

    if (snapshot.docs.isEmpty) return;

    final batch = _firestore.batch();

    for (final doc in snapshot.docs) {
      batch.update(
        doc.reference,
        <String, dynamic>{
          'read': true,
          'readAt': FieldValue.serverTimestamp(),
        },
      );
    }

    await batch.commit();
  }

  Future<void> delete(String notificationId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    await _notifications(uid).doc(notificationId).delete();
  }

  Future<void> dispose() async {
    await _authSubscription?.cancel();
    await _tokenSubscription?.cancel();
    _authSubscription = null;
    _tokenSubscription = null;
  }
}
