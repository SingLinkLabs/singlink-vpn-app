// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/client_controller.dart';
import '../theme.dart';

/// The big round connect button: neutral when off, pulsing rings while
/// connecting, a breathing emerald glow when connected.
class PowerButton extends StatefulWidget {
  const PowerButton({
    super.key,
    required this.state,
    required this.enabled,
    required this.onPressed,
    this.size = 188,
  });

  final ConnState state;
  final bool enabled;
  final VoidCallback onPressed;
  final double size;

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PowerButton old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _sync();
  }

  void _sync() {
    final animate = widget.state != ConnState.disconnected;
    if (animate && !_anim.isAnimating) {
      _anim.repeat();
    } else if (!animate) {
      _anim.stop();
      _anim.value = 0;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pal = StatusPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final s = widget.size;
    final state = widget.state;
    final on = state == ConnState.connected;
    final busy =
        state == ConnState.connecting || state == ConnState.disconnecting;
    final tappable = widget.enabled && !busy;

    final label = switch (state) {
      ConnState.disconnected => 'Connect',
      ConnState.connecting => 'Connecting...',
      ConnState.connected => 'Disconnect',
      ConnState.disconnecting => 'Disconnecting...',
    };

    // Outer box leaves room for the rings / glow.
    final outer = s * 1.42;

    return Semantics(
      button: true,
      enabled: tappable,
      label: label,
      child: SizedBox(
        width: outer,
        height: outer,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final t = _anim.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                if (busy)
                  for (var i = 0; i < 3; i++)
                    _PulseRing(
                      progress: (t + i / 3) % 1,
                      base: s,
                      max: outer,
                      color: pal.connecting,
                    ),
                if (on) ...[
                  // Breathing halo.
                  Container(
                    width: s * (1.16 + 0.04 * math.sin(t * 2 * math.pi)),
                    height: s * (1.16 + 0.04 * math.sin(t * 2 * math.pi)),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Brand.primary.withValues(
                        alpha: dark ? 0.14 : 0.12,
                      ),
                    ),
                  ),
                  Container(
                    width: s * 1.06,
                    height: s * 1.06,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Brand.primary.withValues(
                        alpha: dark ? 0.22 : 0.18,
                      ),
                    ),
                  ),
                ],
                if (!on && !busy)
                  Container(
                    width: s * 1.1,
                    height: s * 1.1,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: pal.unprotected.withValues(
                        alpha: dark ? 0.08 : 0.06,
                      ),
                    ),
                  ),
                _core(context, cs, pal, dark, on, busy, tappable, label, t),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _core(
    BuildContext context,
    ColorScheme cs,
    StatusPalette pal,
    bool dark,
    bool on,
    bool busy,
    bool tappable,
    String label,
    double t,
  ) {
    final s = widget.size;
    final active = on || busy;
    final fg = active
        ? Colors.white
        : (widget.enabled
              ? cs.onSurface.withValues(alpha: 0.78)
              : cs.onSurface.withValues(alpha: 0.3));
    final glow = 0.38 + 0.12 * math.sin(t * 2 * math.pi);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: on
            ? Brand.gradient
            : busy
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  pal.connecting.withValues(alpha: 0.85),
                  Brand.accent.withValues(alpha: 0.7),
                ],
              )
            : null,
        color: active ? null : cs.surfaceContainerLow,
        border: active
            ? null
            : Border.all(color: cs.outlineVariant, width: 1.5),
        boxShadow: on
            ? [
                BoxShadow(
                  color: Brand.primary.withValues(alpha: glow),
                  blurRadius: 48,
                  spreadRadius: 4,
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tappable ? widget.onPressed : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (busy)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Transform.rotate(
                      angle: t * 2 * math.pi,
                      child: CircularProgressIndicator(
                        value: 0.28,
                        strokeWidth: 3,
                        strokeCap: StrokeCap.round,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.power_settings_new_rounded,
                    size: s * 0.34,
                    color: fg,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseRing extends StatelessWidget {
  const _PulseRing({
    required this.progress,
    required this.base,
    required this.max,
    required this.color,
  });

  final double progress;
  final double base;
  final double max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final d = base + (max - base) * Curves.easeOut.transform(progress);
    return IgnorePointer(
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.16 * (1 - progress)),
          border: Border.all(
            color: color.withValues(alpha: 0.5 * (1 - progress)),
            width: 1.5,
          ),
        ),
      ),
    );
  }
}
