// file_picker 的平台替身:让「选择文件 → 读字节 → 解析 → 落库」链路可测。
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// file_picker 11.x 把平台层收成 FilePickerPlatform(公开的静态 API `FilePicker.*`
// 只是转发到 `FilePickerPlatform.instance`),而 FilePickerPlatform 不在包的公开
// 导出里 —— 测试要装替身只能走实现路径导入。这是刻意接受的耦合:包升级改布局时
// 这里会在编译期直接炸出来,而不是让测试静默失效。
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';

/// 可编程的 file_picker 替身。
///
/// 默认实现是 `MethodChannelFilePicker`,在 `flutter test` 下没有原生侧响应 ——
/// 任何走文件选择的路径都测不到。装上本替身就能把「选择文件 → 读字节 → 解析 →
/// 落库」整条链路跑在测试里。
///
/// [pickedPath] 刻意走**真实文件路径**而非内联 bytes:与 App 的移动端口径一致
/// (见 `pickedFileBytes` —— 移动端必须从 path 读,否则 file_picker 会把整个文件
/// 塞进原生 ByteArray 后 OOM),顺带把 `pickedFileBytes` 本身也覆盖到。
class FakeFilePicker extends FilePickerPlatform {
  FakeFilePicker({this.pickedPath, this.savePath});

  /// `pickFiles` 返回的文件路径;null = 用户取消选择。
  String? pickedPath;

  /// `saveFile` 返回的目标路径;null = 用户取消保存。
  String? savePath;

  /// `saveFile` 最近一次收到的字节(断言导出内容用)。
  Uint8List? savedBytes;

  int pickCalls = 0;
  int saveCalls = 0;

  /// 装上替身并返回它,便于测试中途改行为。
  static FakeFilePicker install({String? pickedPath, String? savePath}) {
    final fake = FakeFilePicker(pickedPath: pickedPath, savePath: savePath);
    FilePickerPlatform.instance = fake;
    return fake;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    pickCalls++;
    final path = pickedPath;
    if (path == null) return null;
    final file = File(path);
    return FilePickerResult([
      PlatformFile(name: file.uri.pathSegments.last, path: path, size: await file.length()),
    ]);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saveCalls++;
    savedBytes = bytes;
    return savePath;
  }
}
