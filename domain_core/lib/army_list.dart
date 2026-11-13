/// Parsing the text export of an Army List. Pure and offline: the format is sniffed from the text.
library;

/// One entry of an [ArmyList]: a game-rules unit and how many models it has.
typedef ArmyListEntry = ({String name, int count});

/// An Army List made in another app, as parsed from its text export.
class ArmyList {
  const ArmyList({
    required this.gameSystem,
    required this.faction,
    required this.entries,
  });

  final String gameSystem;
  final String faction;
  final List<ArmyListEntry> entries;
}

/// The Army List in [text] (Warhammer 40k app or Army Forge); null if no parser recognises it.
ArmyList? parseArmyList(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final list = _warhammer40k(lines) ?? _armyForge(lines);
  return list == null || list.entries.isEmpty ? null : list;
}

final _gwUnit = RegExp(r'^(\S.*?)\s*\(\d[\d\s]*\s+[Pp]oints\)');

/// The Warhammer 40k app (10th edition): a title, the faction, the detachment and battle size, then sections.
ArmyList? _warhammer40k(List<String> lines) {
  final text = lines.where((l) => l.trim().isNotEmpty).toList();
  if (text.length < 2 || !_gwUnit.hasMatch(text[0])) return null;
  bool header(String l) => l == l.toUpperCase() && l.contains(RegExp('[A-Z]'));
  final units = <(String, List<String>)>[];
  // Unit lines only count after the first section header: the title and battle size look like them.
  // Section headers and the `Exported with…` footer never match a unit line.
  for (final line in text.skipWhile((l) => !header(l.trim()))) {
    if (line.startsWith(RegExp(r'\s'))) {
      units.lastOrNull?.$2.add(line);
    } else if (_gwUnit.firstMatch(line) case final m?) {
      units.add((m[1]!, []));
    }
  }
  return ArmyList(
    gameSystem: 'Warhammer 40,000',
    faction: text[1].trim(),
    entries: [
      for (final (name, block) in units) (name: name, count: _gwModels(block)),
    ],
  );
}

/// The sum of a unit's model lines: top-level `• Nx …` lines followed by a deeper line; 1 if none.
int _gwModels(List<String> block) {
  int indent(String l) => l.length - l.trimLeft().length;
  var models = 0;
  for (final (i, line) in block.indexed) {
    final m = RegExp(r'^\s*•\s*(\d+)x ').firstMatch(line);
    if (m != null &&
        indent(line) == indent(block.first) &&
        i + 1 < block.length &&
        indent(block[i + 1]) > indent(line)) {
      models += int.parse(m[1]!);
    }
  }
  return models == 0 ? 1 : models;
}

final _afHeader = RegExp(r'^\+\+ (.+?) \(v[^)]*\)');
final _afUnit = RegExp(r'^(?:(\d+)x )?(.+?) \[(\d+)\] Q\d\+ D\d\+ \| \d+pts');
const _afGameSystems = {
  'GF': 'Grimdark Future',
  'GFF': 'Grimdark Future: Firefight',
  'AOF': 'Age of Fantasy',
  'AOFS': 'Age of Fantasy: Skirmish',
  'AOFR': 'Age of Fantasy: Regiments',
};

/// Army Forge (One Page Rules): `++ [ListName - ]Book (vX)[, …] [CODE Npts] … ++`, then one line per unit.
ArmyList? _armyForge(List<String> lines) {
  final first = lines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  final header = _afHeader.firstMatch(first.trim());
  if (header == null || first.trim().startsWith('+++')) return null;
  final code = RegExp(r'\[(\w+) \d+pts\]').firstMatch(first)?[1] ?? '';
  return ArmyList(
    gameSystem: _afGameSystems[code] ?? code,
    faction: header[1]!.split(' - ').last,
    entries: [
      for (final l in lines)
        if (_afUnit.firstMatch(l.trim()) case final m?)
          (name: m[2]!, count: int.parse(m[3]!) * int.parse(m[1] ?? '1')),
    ],
  );
}
