class SseEvent {
  final String? event;
  final String data;
  const SseEvent(this.event, this.data);
}

Stream<SseEvent> parseSse(Stream<String> lines) async* {
  String? event;
  final data = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      final joined = data.join('\n');
      if (joined.isNotEmpty) yield SseEvent(event, joined);
      event = null;
      data.clear();
    } else if (line.startsWith('event:')) {
      event = line.substring('event:'.length).trim();
    } else if (line.startsWith('data:')) {
      data.add(line.substring('data:'.length).trim());
    }
  }
  final joined = data.join('\n');
  if (joined.isNotEmpty) yield SseEvent(event, joined);
}
