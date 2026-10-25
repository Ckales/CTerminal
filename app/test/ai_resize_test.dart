import 'dart:convert';

import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/theme.dart';
import 'package:cterminal/ui/ai_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends Fake implements RustLibApi {
  String history = '[]';
  bool failHistoryLoad = false;

  @override
  String crateApiAiAiHistoryLoad() {
    if (failHistoryLoad) throw StateError('invalid history');
    return history;
  }

  @override
  void crateApiAiAiHistorySave({required String json}) {
    history = json;
  }

  @override
  String crateApiAiAiHistoryResume({required String messagesJson}) =>
      messagesJson;

  @override
  String crateApiSettingsColorSchemes() => '[]';

  @override
  bool crateApiAiAiStatus() => false;

  @override
  String crateApiAiAiPresetsDefaults() => jsonEncode([
    {'id': 'general', 'name': '通用', 'prompt': ''},
  ]);
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeApi()));

  testWidgets('拖动只调整 dock 尺寸并保留草稿和另一方向尺寸', (tester) async {
    final app = AppState(
      config: {
        'hotkeys': <String, dynamic>{},
        'application': <String, dynamic>{'englishInputOnActivate': false},
        'appearance': <String, dynamic>{},
        'ai': <String, dynamic>{
          'baseUrl': '',
          'model': '',
          'panelPosition': 'right',
          'activePreset': 'general',
        },
      },
    )..aiVisible = true;

    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: AppTheme(
          colors: AppColors.dark,
          child: MaterialApp(
            theme: materialTheme(AppColors.dark),
            home: const Scaffold(
              body: AiWorkspace(child: ColoredBox(color: Colors.black)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('ai-dock-panel'));
    final handle = find.byKey(const ValueKey('ai-dock-resize-handle'));
    expect(tester.getSize(panel).width, 380);
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'keep draft',
    );
    await tester.pump();

    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveBy(const Offset(-30, 0));
    await drag.moveBy(const Offset(-50, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, 460);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-input')))
          .controller!
          .text,
      'keep draft',
    );

    await tester.binding.setSurfaceSize(const Size(650, 700));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, closeTo(422.5, 0.01));
    await tester.drag(handle, const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, closeTo(402.5, 0.01));
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pumpAndSettle();

    (app.config['ai'] as Map<String, dynamic>)['panelPosition'] = 'bottom';
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 310);

    await tester.drag(handle, const Offset(0, -70));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, 380);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-input')))
          .controller!
          .text,
      'keep draft',
    );

    (app.config['ai'] as Map<String, dynamic>)['panelPosition'] = 'right';
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, closeTo(402.5, 0.01));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-input')))
          .controller!
          .text,
      'keep draft',
    );

    await tester.pumpWidget(const SizedBox());
    app.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
