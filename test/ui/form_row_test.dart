// 设置行通用件:开关 key 透传与回调、移动滑块禁用态、桌面开关行 key。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/form_row.dart';
import 'package:microscritt/ui/theme/app_theme.dart';

void main() {
  testWidgets('SettingsSwitchTile 保留 SwitchListTile 类型并透传 key', (tester) async {
    bool? changed;
    const switchKey = ValueKey('tile_switch');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsSwitchTile(
            switchTileKey: switchKey,
            title: '开关行',
            description: '开关说明',
            value: true,
            onChanged: (v) => changed = v,
          ),
        ),
      ),
    );

    final tile = tester.widget<SwitchListTile>(find.byKey(switchKey));
    expect(tile.value, isTrue);
    expect(find.text('开关行'), findsOneWidget);
    expect(find.text('开关说明'), findsOneWidget);

    await tester.tap(find.byKey(switchKey));
    await tester.pump();
    expect(changed, isFalse);
  });

  testWidgets('SettingsSwitchTile 禁用时保留取值但不可切换', (tester) async {
    bool? changed;
    const switchKey = ValueKey('tile_switch_disabled');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsSwitchTile(
            switchTileKey: switchKey,
            title: '依赖未满足',
            description: '仅 Agentic 模式可用',
            value: true,
            enabled: false,
            onChanged: (v) => changed = v,
          ),
        ),
      ),
    );

    final tile = tester.widget<SwitchListTile>(find.byKey(switchKey));
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNull);
    await tester.tap(find.byKey(switchKey));
    await tester.pump();
    expect(changed, isNull);
  });

  testWidgets('SettingsSliderTile 禁用时滑块不可操作', (tester) async {
    const sliderKey = ValueKey('tile_slider');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsSliderTile(
            title: '滑块行',
            valueLabel: '10',
            value: 10,
            min: 0,
            max: 20,
            sliderKey: sliderKey,
            enabled: false,
            onChanged: (_) {},
            onChangeEnd: (_) {},
          ),
        ),
      ),
    );

    final slider = tester.widget<Slider>(find.byKey(sliderKey));
    expect(slider.onChanged, isNull);
    expect(slider.onChangeEnd, isNull);
    expect(find.text('滑块行'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
  });

  testWidgets('SettingsDropdown 透传 key 并回传选中值', (tester) async {
    int? changed;
    const dropdownKey = ValueKey('row_dropdown');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsDropdown<int>(
            dropdownKey: dropdownKey,
            value: 5,
            items: const [
              DropdownMenuItem(value: 0, child: Text('关闭')),
              DropdownMenuItem(value: 5, child: Text('最多 5 条')),
              DropdownMenuItem(value: 10, child: Text('最多 10 条')),
            ],
            onChanged: (v) => changed = v,
          ),
        ),
      ),
    );

    final dropdown = tester.widget<DropdownButton<int>>(
      find.byKey(dropdownKey),
    );
    expect(dropdown.value, 5);
    expect(dropdown.underline, isA<SizedBox>());

    await tester.tap(find.byKey(dropdownKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最多 10 条').last);
    await tester.pumpAndSettle();
    expect(changed, 10);
  });

  testWidgets('SettingsSliderControl 把 key 放在内部 Slider 上', (tester) async {
    const sliderKey = ValueKey('control_slider');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsSliderControl(
            sliderKey: sliderKey,
            valueLabel: '60%',
            value: 0.6,
            min: 0.3,
            max: 0.9,
            enabled: false,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final slider = tester.widget<Slider>(find.byKey(sliderKey));
    expect(slider.value, 0.6);
    expect(slider.onChanged, isNull);
    expect(find.text('60%'), findsOneWidget);
  });

  testWidgets('SettingsSwitchRow 把 key 放在内部 Switch 上并回调', (tester) async {
    bool? changed;
    const switchKey = ValueKey('row_switch');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsSwitchRow(
            switchKey: switchKey,
            title: '桌面开关',
            description: '桌面开关说明',
            value: false,
            onChanged: (v) => changed = v,
          ),
        ),
      ),
    );

    final control = tester.widget<Switch>(find.byKey(switchKey));
    expect(control.value, isFalse);
    await tester.tap(find.byKey(switchKey));
    await tester.pump();
    expect(changed, isTrue);
  });
}
