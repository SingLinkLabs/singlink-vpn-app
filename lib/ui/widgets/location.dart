import 'package:flutter/material.dart';

import '../../core/client_controller.dart';
import '../../models/location.dart';
import '../../models/profile.dart';

/// Round flag badge.
class FlagBadge extends StatelessWidget {
  const FlagBadge({
    super.key,
    required this.flag,
    this.size = 44,
    this.background,
  });
  final String flag;
  final double size;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? cs.surfaceContainer,
        shape: BoxShape.circle,
      ),
      child: Text(flag, style: TextStyle(fontSize: size * 0.52, height: 1.1)),
    );
  }
}

/// Main-screen card showing the selected / connected location.
class LocationCard extends StatelessWidget {
  const LocationCard({super.key, required this.c, required this.onTap});

  final ClientController c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final p = c.target;
    final loc = p == null ? null : locationFor(p.displayName);

    final caption = switch (c.conn) {
      ConnState.connected => '已連線地區',
      ConnState.connecting => '正在連線至',
      _ => c.autoSelect ? '快速連線' : '選擇的地區',
    };

    final title = loc?.city ?? '尚未新增伺服器';
    final subtitle = p == null
        ? '點此新增伺服器'
        : (loc!.known && loc.city != p.displayName ? p.displayName : null);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              FlagBadge(flag: loc?.flag ?? '🌐'),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      caption,
                      style: text.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (c.autoSelect && p != null) ...[
                const _Chip(label: '自動', icon: Icons.bolt_rounded),
                const SizedBox(width: 4),
              ],
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「選擇地區」 bottom sheet.
Future<void> showLocationSheet(
  BuildContext context,
  ClientController c, {
  required VoidCallback onManageServers,
}) {
  if (c.isConnected && c.latencyMs == null) c.measureLatency();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.94,
      builder: (context, scroll) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => _LocationList(
          c: c,
          scroll: scroll,
          onPicked: () => Navigator.pop(sheetContext),
          onManageServers: () {
            Navigator.pop(sheetContext);
            onManageServers();
          },
        ),
      ),
    ),
  );
}

class _LocationList extends StatelessWidget {
  const _LocationList({
    required this.c,
    required this.scroll,
    required this.onPicked,
    required this.onManageServers,
  });

  final ClientController c;
  final ScrollController scroll;
  final VoidCallback onPicked;
  final VoidCallback onManageServers;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final auto = c.autoProfile;
    final autoLoc = auto == null ? null : locationFor(auto.displayName);
    final selectedId = c.autoSelect ? null : c.target?.id;

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Text(
            '選擇地區',
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        _Tile(
          selected: c.autoSelect,
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.bolt_rounded, color: cs.primary),
          ),
          title: '快速連線（自動）',
          subtitle: autoLoc == null
              ? '自動使用上次連線的地區'
              : '上次使用：${autoLoc.flag} ${autoLoc.city}',
          trailing: null,
          onTap: c.profiles.isEmpty
              ? null
              : () {
                  c.chooseAuto();
                  onPicked();
                },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 18, 8, 6),
          child: Text(
            '所有地區',
            style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        if (c.profiles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Text(
              '尚未新增伺服器。請到「設定 → 新增伺服器」貼上連結。',
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        for (final p in c.profiles) _serverTile(context, p, selectedId),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onManageServers,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新增或管理伺服器'),
          ),
        ),
      ],
    );
  }

  Widget _serverTile(BuildContext context, Profile p, String? selectedId) {
    final loc = locationFor(p.displayName);
    final connected = c.connectedId == p.id;
    final String latency;
    if (connected && c.latencyMs != null) {
      latency = '${c.latencyMs} ms';
    } else if (connected && c.measuring) {
      latency = '測速中';
    } else {
      latency = '—';
    }
    final sub = <String>[
      if (loc.known && loc.city != p.displayName) p.displayName,
      if (connected) '已連線',
      if (p.isExpired) '已到期',
    ].join(' · ');

    return _Tile(
      selected: p.id == selectedId,
      leading: FlagBadge(
        flag: loc.flag,
        background: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      title: loc.city,
      subtitle: sub.isEmpty ? null : sub,
      trailing: _Latency(
        text: latency,
        active: connected && c.latencyMs != null,
      ),
      onTap: () {
        c.chooseServer(p.id);
        onPicked();
      },
    );
  }
}

class _Latency extends StatelessWidget {
  const _Latency({required this.text, required this.active});
  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.network_cell_rounded,
          size: 16,
          color: active
              ? cs.primary
              : cs.onSurfaceVariant.withValues(alpha: 0.5),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: active ? cs.primary : cs.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.selected,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });

  final bool selected;
  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.10)
            : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected
                ? cs.primary.withValues(alpha: 0.6)
                : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: onTap,
          leading: leading,
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?trailing,
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle_rounded, color: cs.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
