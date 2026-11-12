// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_store.dart';
import '../core/client_controller.dart';
import '../legal.dart';
import '../models/location.dart';
import '../models/profile.dart';
import 'format.dart';
import 'widgets/location.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.c, this.openAddServer = false});

  final ClientController c;

  /// Open the "Add server" dialog right away (first run, empty list).
  final bool openAddServer;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ClientController get c => widget.c;

  @override
  void initState() {
    super.initState();
    if (widget.openAddServer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _addServer();
      });
    }
  }

  Future<void> _addServer() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddServerDialog(c: c),
    );
    if (added == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Server added')));
    }
  }

  Future<void> _delete(Profile p) async {
    final loc = locationFor(p.displayName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete server'),
        content: Text(
          'Remove "${loc.flag} ${p.displayName}" from your list?'
          '${c.connectedId == p.id ? '\nYou are connected to it, so it will disconnect first.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await c.deleteProfile(p.id);
  }

  Future<void> _editPort() async {
    final ctrl = TextEditingController(text: '${c.port}');
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          Future<void> save() async {
            final err =
                validatePort(ctrl.text) ??
                await c.setPort(int.parse(ctrl.text.trim()));
            if (err != null) {
              setLocal(() => error = err);
            } else if (context.mounted) {
              Navigator.pop(context);
            }
          }

          return AlertDialog(
            title: const Text('Local port'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => save(),
              decoration: InputDecoration(
                hintText: '$defaultPort',
                errorText: error,
                helperText:
                    'Default $defaultPort. Change it only if another app is using it.',
                helperMaxLines: 2,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => ctrl.text = '$defaultPort',
                child: const Text('Reset to default'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: save, child: const Text('Save')),
            ],
          );
        },
      ),
    );
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final locked = c.conn != ConnState.disconnected;
        final mono = Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: 'Menlo',
          color: cs.onSurfaceVariant,
        );
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  const _Section('Servers'),
                  _Group(
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.add_circle_rounded,
                          color: cs.primary,
                        ),
                        title: const Text('Add server'),
                        subtitle: const Text(
                          'Paste a link or import from the clipboard',
                        ),
                        enabled: c.coreAvailable,
                        onTap: _addServer,
                      ),
                      for (final p in c.profiles) _serverTile(p),
                    ],
                  ),
                  if (c.profiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Text(
                        'Your server list is empty. Add a server, then choose a location on the main screen and connect.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  const _Section('Connection'),
                  _Group(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.public_rounded),
                        title: const Text('System-wide proxy'),
                        subtitle: Text(
                          c.systemProxySupported
                              ? 'Route every app through SingLinkVPN while connected. Your settings are restored when you disconnect or quit.'
                              : 'Not supported on this platform yet',
                        ),
                        value: c.systemProxyEnabled,
                        onChanged: c.systemProxySupported
                            ? c.setSystemProxy
                            : null,
                      ),
                    ],
                  ),
                  const _Section('Advanced'),
                  _Group(
                    children: [
                      if (c.core.usesLocalProxy) ...[
                        ListTile(
                          leading: const Icon(Icons.settings_ethernet_rounded),
                          title: const Text('Local port'),
                          subtitle: Text(
                            locked
                                ? 'Disconnect first to change it'
                                : 'Default $defaultPort',
                          ),
                          trailing: Text('${c.port}', style: mono),
                          enabled: !locked,
                          onTap: _editPort,
                        ),
                        ListTile(
                          leading: const Icon(Icons.lan_outlined),
                          title: const Text('Local proxy'),
                          subtitle: const Text('SOCKS5, for manual setup'),
                          trailing: SelectableText(c.listen, style: mono),
                        ),
                      ],
                      ListTile(
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: const Text('Connection log'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => _LogPage(c: c),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const _Section('About'),
                  _Group(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.memory_rounded),
                        title: const Text('Core version'),
                        trailing: Text(
                          c.coreVersion?.version ?? 'Not loaded',
                          style: mono,
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.verified_outlined),
                        title: const Text('Protocol'),
                        trailing: Text(
                          c.coreVersion?.protocol.isNotEmpty == true
                              ? c.coreVersion!.protocol
                              : 'SingLink Protocol',
                          style: mono,
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: const Text('Licenses'),
                        subtitle: const Text(kCopyright),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'SingLinkVPN',
                          applicationLegalese: kAttribution,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _serverTile(Profile p) {
    final loc = locationFor(p.displayName);
    final cs = Theme.of(context).colorScheme;
    final expiry = p.expiresAt == null
        ? 'No expiry'
        : (p.isExpired ? 'Expired' : 'Expires ${formatDate(p.expiresAt!)}');
    final host = p.server.contains(':')
        ? p.server.substring(0, p.server.lastIndexOf(':'))
        : p.server;
    return ListTile(
      leading: FlagBadge(flag: loc.flag, size: 38),
      title: Text(p.displayName),
      subtitle: Text(
        '$host · $expiry',
        style: TextStyle(color: p.isExpired ? cs.error : null),
      ),
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline_rounded),
        onPressed: () => _delete(p),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(indent: 16, endIndent: 16),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog({required this.c});
  final ClientController c;

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _working = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit(String link) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    final err = await widget.c.importLink(link);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _working = false;
      _error = err.message;
    });
  }

  Future<void> _fromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() => _error = 'There is no text on the clipboard');
      return;
    }
    _ctrl.text = text;
    await _submit(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add server'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste the server link you received (it starts with singlink://).',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              enabled: !_working,
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
              decoration: InputDecoration(
                hintText: 'singlink://…',
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _working ? null : _fromClipboard,
                icon: const Icon(Icons.content_paste_rounded),
                label: const Text('Import from clipboard'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _working ? null : () => _submit(_ctrl.text),
          child: _working
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

class _LogPage extends StatelessWidget {
  const _LogPage({required this.c});
  final ClientController c;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Connection log')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final items = c.logs.reversed.toList();
          if (items.isEmpty) {
            return const Center(child: Text('No entries yet'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, i) {
              final e = items[i];
              final color = switch (e.level) {
                LogLevel.error => cs.error,
                LogLevel.success => cs.primary,
                LogLevel.info => cs.onSurface,
              };
              return SelectableText.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${formatClock(e.time)}  ',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontFamily: 'Menlo',
                        fontSize: 12,
                      ),
                    ),
                    TextSpan(
                      text: e.message,
                      style: TextStyle(color: color, fontSize: 13),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
