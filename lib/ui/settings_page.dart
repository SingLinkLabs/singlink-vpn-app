import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_store.dart';
import '../core/client_controller.dart';
import '../models/location.dart';
import '../models/profile.dart';
import 'format.dart';
import 'widgets/location.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.c, this.openAddServer = false});

  final ClientController c;

  /// Open the 「新增伺服器」 dialog right away (first run, empty list).
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
      ).showSnackBar(const SnackBar(content: Text('已新增伺服器')));
    }
  }

  Future<void> _delete(Profile p) async {
    final loc = locationFor(p.displayName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除伺服器'),
        content: Text(
          '要從列表移除「${loc.flag} ${p.displayName}」嗎？'
          '${c.connectedId == p.id ? '\n目前正在使用，會先中斷連線。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
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
            title: const Text('本機埠'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => save(),
              decoration: InputDecoration(
                hintText: '$defaultPort',
                errorText: error,
                helperText: '預設 $defaultPort。只有被其他程式佔用時才需要更改。',
                helperMaxLines: 2,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => ctrl.text = '$defaultPort',
                child: const Text('還原預設'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: save, child: const Text('儲存')),
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
          appBar: AppBar(title: const Text('設定')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  const _Section('伺服器'),
                  _Group(
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.add_circle_rounded,
                          color: cs.primary,
                        ),
                        title: const Text('新增伺服器'),
                        subtitle: const Text('貼上連結或從剪貼簿匯入'),
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
                        '伺服器列表是空的。新增後即可在主畫面選擇地區並連線。',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  const _Section('連線'),
                  _Group(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.public_rounded),
                        title: const Text('系統全局代理'),
                        subtitle: Text(
                          c.systemProxySupported
                              ? '連線時讓整台電腦的 App 經由星連VPN，中斷連線或關閉 App 時自動還原原本的設定'
                              : '此平台尚未支援',
                        ),
                        value: c.systemProxyEnabled,
                        onChanged: c.systemProxySupported
                            ? c.setSystemProxy
                            : null,
                      ),
                    ],
                  ),
                  const _Section('進階'),
                  _Group(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.settings_ethernet_rounded),
                        title: const Text('本機埠'),
                        subtitle: Text(
                          locked ? '請先中斷連線再修改' : '預設 $defaultPort',
                        ),
                        trailing: Text('${c.port}', style: mono),
                        enabled: !locked,
                        onTap: _editPort,
                      ),
                      ListTile(
                        leading: const Icon(Icons.lan_outlined),
                        title: const Text('本機代理'),
                        subtitle: const Text('SOCKS5，手動設定用'),
                        trailing: SelectableText(c.listen, style: mono),
                      ),
                      ListTile(
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: const Text('連線紀錄'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => _LogPage(c: c),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const _Section('關於'),
                  _Group(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.memory_rounded),
                        title: const Text('核心版本'),
                        trailing: Text(
                          c.coreVersion?.version ?? '未載入',
                          style: mono,
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.verified_outlined),
                        title: const Text('協議'),
                        trailing: Text(
                          c.coreVersion?.protocol.isNotEmpty == true
                              ? c.coreVersion!.protocol
                              : 'SingLink Protocol',
                          style: mono,
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
        ? '不限期'
        : (p.isExpired ? '已到期' : '到期 ${formatDate(p.expiresAt!)}');
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
        tooltip: '刪除',
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
      setState(() => _error = '剪貼簿沒有文字');
      return;
    }
    _ctrl.text = text;
    await _submit(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增伺服器'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('貼上你收到的伺服器連結（以 singlink:// 開頭）。'),
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
                label: const Text('從剪貼簿匯入'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _working ? null : () => _submit(_ctrl.text),
          child: _working
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('新增'),
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
      appBar: AppBar(title: const Text('連線紀錄')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final items = c.logs.reversed.toList();
          if (items.isEmpty) {
            return const Center(child: Text('尚無紀錄'));
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
