// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../core/client_controller.dart';
import '../legal.dart';
import 'format.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets/location.dart';
import 'widgets/notices.dart';
import 'widgets/power_button.dart';
import 'widgets/speed_cards.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.c});

  final ClientController c;

  void _openSettings(BuildContext context, {bool addServer = false}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(c: c, openAddServer: addServer),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final pal = StatusPalette.of(context);
        final glow = switch (c.conn) {
          ConnState.connected => Brand.primary,
          ConnState.connecting || ConnState.disconnecting => pal.connecting,
          ConnState.disconnected => pal.unprotected,
        };
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Scaffold(
          body: AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.35),
                radius: 0.9,
                colors: [
                  glow.withValues(
                    alpha: c.isConnected
                        ? (dark ? 0.20 : 0.16)
                        : (dark ? 0.10 : 0.07),
                  ),
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0),
                ],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    children: [
                      _Header(onSettings: () => _openSettings(context)),
                      Expanded(
                        child: CustomScrollView(
                          slivers: [
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: _Body(
                                c: c,
                                onLocations: () => c.profiles.isEmpty
                                    ? _openSettings(context, addServer: true)
                                    : showLocationSheet(
                                        context,
                                        c,
                                        onManageServers: () =>
                                            _openSettings(context),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: Brand.gradient,
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.shield_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'SingLinkVPN',
            style: text.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.c, required this.onLocations});
  final ClientController c;
  final VoidCallback onLocations;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pal = StatusPalette.of(context);

    final (headline, sub, color, icon) = switch (c.conn) {
      ConnState.connected => (
        'Protected',
        'Your traffic is encrypted',
        pal.protected,
        Icons.verified_user_rounded,
      ),
      ConnState.connecting => (
        'Connecting',
        'Setting up a secure connection...',
        pal.connecting,
        Icons.shield_outlined,
      ),
      ConnState.disconnecting => (
        'Disconnecting',
        'Restoring your network settings...',
        pal.connecting,
        Icons.shield_outlined,
      ),
      ConnState.disconnected => (
        'Not protected',
        'Connect to encrypt and protect your traffic',
        pal.unprotected,
        Icons.gpp_maybe_rounded,
      ),
    };

    final canConnect = c.coreAvailable && c.target != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!c.coreAvailable) ...[
            const SizedBox(height: 8),
            CoreMissingBanner(location: c.core.location),
          ],
          const Spacer(),
          const SizedBox(height: 12),
          // Status headline.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(width: 8),
              Text(
                headline,
                style: text.headlineSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Center(
            child: PowerButton(
              state: c.conn,
              enabled: canConnect || c.conn != ConnState.disconnected,
              onPressed: c.toggle,
            ),
          ),
          const SizedBox(height: 4),
          // Timer + exit IP.
          SizedBox(
            height: 36,
            child: Center(
              child: Text(
                c.isConnected ? formatTimer(c.elapsed) : '00:00:00',
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: c.isConnected
                      ? cs.onSurface
                      : cs.onSurfaceVariant.withValues(alpha: 0.45),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your IP: ${_ip()}',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 16),
          if (c.error != null) ...[
            ErrorNotice(error: c.error!, onClose: c.dismissError),
            const SizedBox(height: 12),
          ],
          if (c.proxyWarning != null && c.isConnected) ...[
            WarningNotice(message: c.proxyWarning!),
            const SizedBox(height: 12),
          ],
          const Spacer(),
          LocationCard(c: c, onTap: onLocations),
          const SizedBox(height: 12),
          SpeedCards(c: c),
          const SizedBox(height: 14),
          // Required attribution (NOTICE, Apache License 2.0 section 4(d)).
          Text(
            kMadeBy,
            textAlign: TextAlign.center,
            style: text.labelSmall?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.75),
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  String _ip() {
    if (!c.isConnected) return '—';
    if (c.exitIp != null) return c.exitIp!;
    return c.exitIpLoading ? 'Checking...' : '—';
  }
}
