import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/api/update.dart';
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/theme.dart';
import 'package:cterminal/ui/tab_bar.dart';
import 'package:cterminal/update_check.dart';
import 'package:cterminal/window_control.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends Fake implements RustLibApi {
  @override
  String crateApiSettingsColorSchemes() => '[]';

  @override
  Future<void> crateApiSettingsStateSave({required String json}) async {}
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeApi()));

  Future<AppState> mountBar(
    WidgetTester tester, {
    int count = 20,
    int pinned = 0,
    bool flexible = false,
    double width = 480,
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      WindowControl.channel,
      (_) async => null,
    );
    final app = AppState(
      config: {
        'hotkeys': <String, dynamic>{},
        'application': <String, dynamic>{},
        'appearance': <String, dynamic>{'flexibleTabs': flexible},
      },
    );
    for (var i = 0; i < count; i++) {
      app.tabs.add(WelcomeTab()..pinned = i < pinned);
    }
    await tester.binding.setSurfaceSize(Size(width, 200));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      UpdateCheck.available.value = null;
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: AppTheme(
          colors: AppColors.dark,
          child: MaterialApp(
            theme: materialTheme(AppColors.dark),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: AppTabBar(vertical: false),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('标签过多时右侧按钮仍在窗口内且可点击', (tester) async {
    final app = await mountBar(tester);
    expect(tester.takeException(), isNull);
    for (final label in ['新建标签页', '配置和连接', 'AI 助手', '设置']) {
      final button = find.byTooltip(label);
      expect(tester.getRect(button).right, lessThanOrEqualTo(480));
      expect(button.hitTestable(), findsOneWidget);
    }
    await tester.tap(find.byTooltip('AI 助手'));
    await tester.pump();
    expect(app.aiVisible, isTrue);
  });

  for (final flexible in [false, true]) {
    testWidgets('标签可横向滚动，操作按钮位置不变（铺满：$flexible）', (tester) async {
      await mountBar(tester, flexible: flexible);
      expect(tester.takeException(), isNull);
      final buttonRect = tester.getRect(find.byTooltip('设置'));
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ReorderableListView)),
          scrollDelta: const Offset(160, 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(tester.getRect(find.byTooltip('设置')), buttonRect);
      expect(find.byTooltip('设置').hitTestable(), findsOneWidget);
    });
  }

  testWidgets('大量固定标签和更新提示不会挤出操作按钮', (tester) async {
    UpdateCheck.available.value = const UpdateInfo(
      latest: 'v2.1.0',
      url: 'https://example.com/releases/v2.1.0',
      newer: true,
    );
    await mountBar(tester, pinned: 20, flexible: true);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('设置').hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byTooltip('设置')).right, lessThanOrEqualTo(480));
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('新建和切换到两端标签时自动滚入可见区域', (tester) async {
    final app = await mountBar(tester);
    void expectActiveVisible() {
      final viewport = tester.getRect(find.byType(ReorderableListView));
      final active = tester.getRect(find.byKey(ValueKey(app.activeTab!.key)));
      expect(active.left, greaterThanOrEqualTo(viewport.left));
      expect(active.right, lessThanOrEqualTo(viewport.right));
    }

    app.selectTab(app.tabs.length - 1);
    await tester.pumpAndSettle();
    expectActiveVisible();
    await tester.pump(const Duration(seconds: 1));
    app.tabs.add(WelcomeTab());
    app.selectTab(app.tabs.length - 1);
    await tester.pumpAndSettle();
    expectActiveVisible();
    app.selectTab(0);
    await tester.pumpAndSettle();
    expectActiveVisible();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('鼠标滚轮可浏览横向标签且不会被普通重建拉回', (tester) async {
    final app = await mountBar(tester);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ReorderableListView)),
        scrollDelta: const Offset(0, 160),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, greaterThan(0));
    final offset = scrollable.position.pixels;
    app.toggleAi();
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, offset);
  });

  testWidgets('固定标签占满视口时普通标签仍保留最小宽度', (tester) async {
    final app = await mountBar(tester, count: 21, pinned: 20, flexible: true);
    expect(tester.takeException(), isNull);
    app.selectTab(20);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final active = tester.getRect(find.byKey(ValueKey(app.activeTab!.key)));
    expect(active.width, greaterThanOrEqualTo(90));
    expect(
      active.right,
      lessThanOrEqualTo(tester.getRect(find.byType(ReorderableListView)).right),
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('增加标签和缩窄窗口时按钮靠右且当前标签可见', (tester) async {
    final app = await mountBar(tester, count: 1, width: 1000);
    final settingsRect = tester.getRect(find.byTooltip('设置'));
    app.tabs.addAll(List.generate(19, (_) => WelcomeTab()));
    app.selectTab(19);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byTooltip('设置')), settingsRect);

    await tester.binding.setSurfaceSize(const Size(480, 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byTooltip('设置')).right, 476);
    final active = tester.getRect(find.byKey(ValueKey(app.activeTab!.key)));
    final viewport = tester.getRect(find.byType(ReorderableListView));
    expect(active.left, greaterThanOrEqualTo(viewport.left));
    expect(active.right, lessThanOrEqualTo(viewport.right));
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(app.activeTab, isA<SettingsTab>());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('横向滚动布局仍支持拖动标签排序', (tester) async {
    final app = await mountBar(tester, width: 900);
    final first = app.tabs.first;
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey(first.key))),
    );
    await tester.pump();
    await drag.moveBy(const Offset(20, 0));
    await tester.pump();
    await drag.moveBy(const Offset(300, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await drag.up();
    await tester.pumpAndSettle();
    expect(app.tabs.indexOf(first), 2);
    expect(find.byTooltip('设置').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
