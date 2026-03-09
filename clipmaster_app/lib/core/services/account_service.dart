import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import '../utils/env_config.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Supported account providers for OAuth login.
enum AccountProvider { youtube, twitch }

/// A connected user account with OAuth tokens.
class ConnectedAccount {
  final AccountProvider provider;
  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final String username;
  final String? avatarUrl;
  final DateTime connectedAt;

  ConnectedAccount({
    required this.provider,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    required this.username,
    this.avatarUrl,
    DateTime? connectedAt,
  }) : connectedAt = connectedAt ?? DateTime.now();

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  Map<String, dynamic> toJson() => {
        'provider': provider.name,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt?.toIso8601String(),
        'username': username,
        'avatarUrl': avatarUrl,
        'connectedAt': connectedAt.toIso8601String(),
      };

  factory ConnectedAccount.fromJson(Map<String, dynamic> j) =>
      ConnectedAccount(
        provider: AccountProvider.values.byName(j['provider'] as String),
        accessToken: j['accessToken'] as String,
        refreshToken: j['refreshToken'] as String?,
        expiresAt: j['expiresAt'] != null
            ? DateTime.parse(j['expiresAt'] as String)
            : null,
        username: j['username'] as String,
        avatarUrl: j['avatarUrl'] as String?,
        connectedAt: DateTime.parse(j['connectedAt'] as String),
      );
}

/// Manages connected YouTube and Twitch accounts via OAuth.
///
/// Uses a local HTTP server to catch OAuth redirects.
/// Client IDs come from .env file:
///   - GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET (for YouTube)
///   - TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET (for Twitch)
class AccountService extends ChangeNotifier {
  static const String _storageKey = 'clipmaster_accounts';

  /// Fixed port for OAuth redirects. Twitch requires the redirect_uri to
  /// exactly match what's registered in the developer console, so we can't
  /// use a random port. Register http://localhost:17548 in both Google Cloud
  /// Console and Twitch Developer Console.
  static const int oauthPort = 17548;
  static const String oauthRedirectUri = 'http://localhost:$oauthPort';

  final FlutterSecureStorage _storage;
  final Map<AccountProvider, ConnectedAccount> _accounts = {};

  AccountService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Load accounts from secure storage.
  Future<void> init() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw != null) {
      try {
        final Map<String, dynamic> map =
            jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final account = ConnectedAccount.fromJson(
              entry.value as Map<String, dynamic>);
          _accounts[account.provider] = account;
        }
        _log.i('Loaded ${_accounts.length} connected accounts.');
      } catch (e) {
        _log.e('Failed to parse stored accounts: $e');
      }
    }
    // Auto-refresh expired tokens on startup.
    for (final provider in AccountProvider.values) {
      await _refreshIfExpired(provider);
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final map = <String, dynamic>{};
    for (final entry in _accounts.entries) {
      map[entry.key.name] = entry.value.toJson();
    }
    await _storage.write(key: _storageKey, value: jsonEncode(map));
  }

  /// Get a connected account (or null).
  ConnectedAccount? getAccount(AccountProvider provider) =>
      _accounts[provider];

  /// Check if the required Client ID is configured in .env.
  bool hasClientId(AccountProvider provider) {
    switch (provider) {
      case AccountProvider.youtube:
        final id = EnvConfig.get('GOOGLE_CLIENT_ID');
        return id != null && id.isNotEmpty;
      case AccountProvider.twitch:
        final id = EnvConfig.get('TWITCH_CLIENT_ID');
        return id != null && id.isNotEmpty;
    }
  }

  /// Start the OAuth flow for a provider.
  ///
  /// Opens the user's browser to the authorization page, catches the
  /// redirect on a local HTTP server, exchanges the code for tokens,
  /// fetches the user profile, and stores everything.
  Future<ConnectedAccount> connect(AccountProvider provider) async {
    switch (provider) {
      case AccountProvider.youtube:
        return _connectYouTube();
      case AccountProvider.twitch:
        return _connectTwitch();
    }
  }

  /// Disconnect (revoke + remove) an account.
  Future<void> disconnect(AccountProvider provider) async {
    _accounts.remove(provider);
    await _persist();
    notifyListeners();
    _log.i('Disconnected ${provider.name} account.');
  }

  // ─────────────────── YouTube OAuth ───────────────────

  Future<ConnectedAccount> _connectYouTube() async {
    final clientId = EnvConfig.get('GOOGLE_CLIENT_ID') ?? '';
    final clientSecret = EnvConfig.get('GOOGLE_CLIENT_SECRET') ?? '';
    if (clientId.isEmpty) {
      throw StateError(
        'GOOGLE_CLIENT_ID not set. Add it to your .env file.\n'
        'Create one at: console.cloud.google.com > APIs & Services > Credentials > OAuth 2.0 Client IDs',
      );
    }

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': oauthRedirectUri,
      'response_type': 'code',
      'scope': 'https://www.googleapis.com/auth/youtube.readonly '
          'https://www.googleapis.com/auth/userinfo.profile',
      'access_type': 'offline',
      'prompt': 'select_account',
    });

    final code = await _runOAuthFlow(authUrl.toString(), oauthPort);

    // Exchange code for tokens.
    final tokenResponse = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': oauthRedirectUri,
        'grant_type': 'authorization_code',
      },
    );

    if (tokenResponse.statusCode != 200) {
      throw StateError(
          'Token exchange failed: ${tokenResponse.statusCode} ${tokenResponse.body}');
    }

    final tokens = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
    final accessToken = tokens['access_token'] as String;
    final refreshToken = tokens['refresh_token'] as String?;
    final expiresIn = tokens['expires_in'] as int? ?? 3600;

    // Fetch user profile.
    final profileResponse = await http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    final profile =
        jsonDecode(profileResponse.body) as Map<String, dynamic>;

    final account = ConnectedAccount(
      provider: AccountProvider.youtube,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      username: (profile['name'] as String?) ?? 'YouTube User',
      avatarUrl: profile['picture'] as String?,
    );

    _accounts[AccountProvider.youtube] = account;
    await _persist();
    notifyListeners();
    _log.i('Connected YouTube account: ${account.username}');
    return account;
  }

  // ─────────────────── Twitch OAuth ───────────────────

  Future<ConnectedAccount> _connectTwitch() async {
    final clientId = EnvConfig.get('TWITCH_CLIENT_ID') ?? '';
    final clientSecret = EnvConfig.get('TWITCH_CLIENT_SECRET') ?? '';
    if (clientId.isEmpty) {
      throw StateError(
        'TWITCH_CLIENT_ID not set. Add it to your .env file.\n'
        'Create one at: dev.twitch.tv/console/apps',
      );
    }

    final authUrl = Uri.https('id.twitch.tv', '/oauth2/authorize', {
      'client_id': clientId,
      'redirect_uri': oauthRedirectUri,
      'response_type': 'code',
      'scope': 'user:read:email channel:read:stream_key',
    });

    final code = await _runOAuthFlow(authUrl.toString(), oauthPort);

    // Exchange code for tokens.
    final tokenResponse = await http.post(
      Uri.parse('https://id.twitch.tv/oauth2/token'),
      body: {
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': oauthRedirectUri,
        'grant_type': 'authorization_code',
      },
    );

    if (tokenResponse.statusCode != 200) {
      throw StateError(
          'Token exchange failed: ${tokenResponse.statusCode} ${tokenResponse.body}');
    }

    final tokens = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
    final accessToken = tokens['access_token'] as String;
    final refreshToken = tokens['refresh_token'] as String?;
    final expiresIn = tokens['expires_in'] as int? ?? 3600;

    // Fetch user profile.
    final profileResponse = await http.get(
      Uri.parse('https://api.twitch.tv/helix/users'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Client-Id': clientId,
      },
    );
    final profileData =
        jsonDecode(profileResponse.body) as Map<String, dynamic>;
    final users = (profileData['data'] as List<dynamic>?) ?? [];
    final user =
        users.isNotEmpty ? users.first as Map<String, dynamic> : {};

    final account = ConnectedAccount(
      provider: AccountProvider.twitch,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      username:
          (user['display_name'] as String?) ?? 'Twitch User',
      avatarUrl: user['profile_image_url'] as String?,
    );

    _accounts[AccountProvider.twitch] = account;
    await _persist();
    notifyListeners();
    _log.i('Connected Twitch account: ${account.username}');
    return account;
  }

  // ─────────────────── Token refresh ───────────────────

  /// Refresh the access token for a provider if it has expired.
  Future<void> _refreshIfExpired(AccountProvider provider) async {
    final account = _accounts[provider];
    if (account == null || !account.isExpired) return;
    if (account.refreshToken == null) return;

    try {
      switch (provider) {
        case AccountProvider.youtube:
          await _refreshYouTube(account);
        case AccountProvider.twitch:
          await _refreshTwitch(account);
      }
    } catch (e) {
      _log.e('Failed to refresh ${provider.name} token: $e');
    }
  }

  Future<void> _refreshYouTube(ConnectedAccount account) async {
    final clientId = EnvConfig.get('GOOGLE_CLIENT_ID') ?? '';
    final clientSecret = EnvConfig.get('GOOGLE_CLIENT_SECRET') ?? '';
    if (clientId.isEmpty) return;

    final response = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': account.refreshToken!,
        'grant_type': 'refresh_token',
      },
    );

    if (response.statusCode != 200) {
      _log.e('YouTube token refresh failed: ${response.statusCode}');
      return;
    }

    final tokens = jsonDecode(response.body) as Map<String, dynamic>;
    final newAccount = ConnectedAccount(
      provider: AccountProvider.youtube,
      accessToken: tokens['access_token'] as String,
      refreshToken: account.refreshToken,
      expiresAt: DateTime.now()
          .add(Duration(seconds: (tokens['expires_in'] as int?) ?? 3600)),
      username: account.username,
      avatarUrl: account.avatarUrl,
      connectedAt: account.connectedAt,
    );

    _accounts[AccountProvider.youtube] = newAccount;
    await _persist();
    _log.i('Refreshed YouTube access token.');
  }

  Future<void> _refreshTwitch(ConnectedAccount account) async {
    final clientId = EnvConfig.get('TWITCH_CLIENT_ID') ?? '';
    final clientSecret = EnvConfig.get('TWITCH_CLIENT_SECRET') ?? '';
    if (clientId.isEmpty) return;

    final response = await http.post(
      Uri.parse('https://id.twitch.tv/oauth2/token'),
      body: {
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': account.refreshToken!,
        'grant_type': 'refresh_token',
      },
    );

    if (response.statusCode != 200) {
      _log.e('Twitch token refresh failed: ${response.statusCode}');
      return;
    }

    final tokens = jsonDecode(response.body) as Map<String, dynamic>;
    final newAccount = ConnectedAccount(
      provider: AccountProvider.twitch,
      accessToken: tokens['access_token'] as String,
      refreshToken: tokens['refresh_token'] as String? ?? account.refreshToken,
      expiresAt: DateTime.now()
          .add(Duration(seconds: (tokens['expires_in'] as int?) ?? 3600)),
      username: account.username,
      avatarUrl: account.avatarUrl,
      connectedAt: account.connectedAt,
    );

    _accounts[AccountProvider.twitch] = newAccount;
    await _persist();
    _log.i('Refreshed Twitch access token.');
  }

  // ─────────────────── Shared helpers ───────────────────

  /// Run the full OAuth flow: open browser, catch redirect, return auth code.
  Future<String> _runOAuthFlow(String authUrl, int port) async {
    final server = await HttpServer.bind('localhost', port);
    _log.d('OAuth redirect server listening on port $port');

    // Open the user's browser.
    _openUrl(authUrl);

    try {
      // Wait for the redirect (with 5-minute timeout).
      final request = await server.first.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw StateError(
            'OAuth timed out. Please try connecting again.'),
      );

      final code = request.uri.queryParameters['code'];
      final error = request.uri.queryParameters['error'];

      if (error != null) {
        // Send error page.
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(
            '<html><body style="font-family:sans-serif;text-align:center;padding:60px;">'
            '<h2>Authorization Denied</h2>'
            '<p>You can close this window.</p></body></html>',
          );
        await request.response.close();
        throw StateError('OAuth denied by user: $error');
      }

      if (code == null || code.isEmpty) {
        request.response
          ..statusCode = 400
          ..write('Missing authorization code');
        await request.response.close();
        throw StateError('No authorization code received.');
      }

      // Send success page.
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '<html><body style="font-family:sans-serif;text-align:center;padding:60px;">'
          '<h2>Connected!</h2>'
          '<p>You can close this window and return to ClipMaster Pro.</p></body></html>',
        );
      await request.response.close();

      return code;
    } finally {
      await server.close();
    }
  }

  void _openUrl(String url) {
    if (Platform.isWindows) {
      // Use rundll32 to avoid cmd.exe interpreting & in URLs as a command separator.
      Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  }
}

/// Riverpod provider for the Account Service.
final accountServiceProvider = ChangeNotifierProvider<AccountService>((ref) {
  return AccountService();
});
