import 'package:domain_core/army_list.dart';
import 'package:test/test.dart';

// The fixtures from issue #85, verbatim.
const layoutA = r'''
GSC rising  (2000 Points)

Genestealer Cults
Final Day
Strike Force (2 000 Points)

CHARACTERS

Patriarch (85 Points)
  • Warlord
  • 1x Patriarch’s claws
  • Enhancements: Enraptured Damnation

BATTLELINE

Acolyte Hybrids with Autopistols (65 Points)
  • 1x Acolyte Leader
     ◦ 1x Autopistol
     ◦ 1x Leader’s bio-weapons
  • 4x Acolyte Hybrid
     ◦ 1x Cult Icon
     ◦ 1x Cult claws and knife
     ◦ 3x Heavy mining tool

Achilles Ridgerunners (95 Points)
  • 1x Armoured hull
  • 1x Heavy mortar

Exported with App Version: v1.43.0 (1), Data Version: v705
''';

const layoutB = r'''
cano (2000 points)

Necrons
Strike Force (2000 points)
Canoptek Court

CHARACTERS

Illuminor Szeras (165 points)
  • 1x Eldritch Lance
    1x Impaling legs

Technomancer (100 points)
  • 1x Staff of light
  • Enhancement: Dimensional Sanctum

BATTLELINE

Necron Warriors (200 points)
  • 20x Necron Warrior
    • 20x Close combat weapon
      20x Gauss reaper
''';

const armyForge = r'''
++ Human Defense Force (v3.4.4) [GF 1970pts] ++

Company Leader [1] Q4+ D5+ | 70pts | Hero, Tough(3), 1x Enforcer(Hold the Line)
CCW (A2), Master Rifle (24", A2)
| Joined to:
Recruits [10] Q6+ D5+ | 70pts | 
10x Rifle (24", A1), 10x CCW (A1)

Sappers [6] Q5+ D5+ | 250pts | Relentless
6x CCW (A1), 6x Rapid Plasma Rifle (24", A2, AP(4))
''';

// A real export from app v2.8.1: points grouped with `.`, an ATTACHED UNITS section.
const grandMasters = r'''
Grey Knights (2.000 Points)

Grey Knights
Warpbane Task Force (3 Detachment Points)
Purge the Foe
Strike Force (2.000 Points)

ATTACHED UNITS

Attached unit 1

Castellan Crowe (105 Points)
  • Attached as: Leader (Character)
  • Warlord
  • 1x Black Blade of Antwyr
  • 1x Purifying Flame
  • 1x Storm Bolter

Purifier Squad (290 Points)
  • Attached as: Bodyguard
  • 1x Knight of the Flame
     ◦ 1x Nemesis force weapon
     ◦ 1x Purifying Flame
     ◦ 1x Storm Bolter
  • 9x Purifier
     ◦ 9x Nemesis force weapon
     ◦ 9x Purifying Flame
     ◦ 9x Storm Bolter

CHARACTERS

Grand Master in Nemesis Dreadknight (240 Points)
  • 1x Fragstorm grenade launcher
  • 1x Heavy psycannon
  • 1x Nemesis daemon greathammer
  • 1x Sublimator

Grand Master in Nemesis Dreadknight (240 Points)
  • 1x Fragstorm grenade launcher
  • 1x Heavy psycannon
  • 1x Nemesis daemon greathammer
  • 1x Sublimator

Grand Master in Nemesis Dreadknight (255 Points)
  • 1x Fragstorm grenade launcher
  • 1x Heavy psycannon
  • 1x Nemesis daemon greathammer
  • 1x Sublimator

BATTLELINE

Strike Squad (125 Points)
  • 1x Justicar
     ◦ 1x Nemesis force weapon
     ◦ 1x Storm Bolter
  • 4x Grey Knight
     ◦ 4x Nemesis force weapon
     ◦ 4x Storm Bolter

OTHER DATASHEETS

Purifier Squad (290 Points)
  • 1x Knight of the Flame
     ◦ 1x Nemesis force weapon
     ◦ 1x Purifying Flame
     ◦ 1x Storm Bolter
  • 9x Purifier
     ◦ 4x Close Combat Weapon
     ◦ 5x Nemesis force weapon
     ◦ 4x Psycannon
     ◦ 9x Purifying Flame
     ◦ 5x Storm Bolter

Purifier Squad (155 Points)
  • 1x Knight of the Flame
     ◦ 1x Nemesis force weapon
     ◦ 1x Purifying Flame
     ◦ 1x Storm Bolter
  • 4x Purifier
     ◦ 2x Close Combat Weapon
     ◦ 2x Nemesis force weapon
     ◦ 2x Psycannon
     ◦ 4x Purifying Flame
     ◦ 2x Storm Bolter

Stormraven Gunship (300 Points)
  • 1x Armoured hull
  • 2x Hurricane bolter
  • 2x Stormstrike missile launcher 
  • 1x Twin heavy plasma cannon
  • 1x Twin multi-melta

Exported with App Version: v2.8.1 (1), Data Version: v995
''';

void main() {
  test('Warhammer 40k app, layout A: wargear under ◦, mixed model types summed, characters and vehicles 1', () {
    final list = parseArmyList(layoutA)!;
    expect(list.gameSystem, 'Warhammer 40,000');
    expect(list.faction, 'Genestealer Cults');
    expect(list.entries, [
      (name: 'Patriarch', count: 1),
      (name: 'Acolyte Hybrids with Autopistols', count: 5),
      (name: 'Achilles Ridgerunners', count: 1),
    ]);
  });

  test('Warhammer 40k app, layout B: continuation lines without a bullet', () {
    final list = parseArmyList(layoutB)!;
    expect(list.gameSystem, 'Warhammer 40,000');
    expect(list.faction, 'Necrons');
    expect(list.entries, [
      (name: 'Illuminor Szeras', count: 1),
      (name: 'Technomancer', count: 1),
      (name: 'Necron Warriors', count: 20),
    ]);
  });

  test('Warhammer 40k app, layout B: a multiple wargear line with a continuation is not models', () {
    final list = parseArmyList(
      layoutB.replaceFirst('1x Eldritch Lance', '2x Eldritch Lance'),
    )!;
    expect(list.entries.first, (name: 'Illuminor Szeras', count: 1));
  });

  test('Warhammer 40k app v2.8.1: dotted points, attached leader and bodyguard stay separate', () {
    final list = parseArmyList(grandMasters)!;
    expect(list.faction, 'Grey Knights');
    expect(list.entries, [
      (name: 'Castellan Crowe', count: 1),
      (name: 'Purifier Squad', count: 10),
      for (var i = 0; i < 3; i++)
        (name: 'Grand Master in Nemesis Dreadknight', count: 1),
      (name: 'Strike Squad', count: 5),
      (name: 'Purifier Squad', count: 10),
      (name: 'Purifier Squad', count: 5),
      (name: 'Stormraven Gunship', count: 1),
    ]);
  });

  test('Warhammer 40k app: text after the points is dropped', () {
    final list = parseArmyList(
      layoutA.replaceFirst(
        'Patriarch (85 Points)',
        'Patriarch (85 Points) WARLORD',
      ),
    )!;
    expect(list.entries.first, (name: 'Patriarch', count: 1));
  });

  test('Army Forge: joined heroes stay separate entries; weapons lines are ignored', () {
    final list = parseArmyList(armyForge)!;
    expect(list.gameSystem, 'Grimdark Future');
    expect(list.faction, 'Human Defense Force');
    expect(list.entries, [
      (name: 'Company Leader', count: 1),
      (name: 'Recruits', count: 10),
      (name: 'Sappers', count: 6),
    ]);
  });

  test('Army Forge: list name, second book, unknown code, Nx multiplier', () {
    final list = parseArmyList(
      '++ My list - Orc Marauders (v3.1), Goblins (v2) [XYZ 500pts] [2 Units] **Balance Invalid** ++\n\n'
      '2x Boyz [10] Q4+ D5+ | 200pts | Furious\nHand Weapons (A1)\n',
    )!;
    expect(list.gameSystem, 'XYZ');
    expect(list.faction, 'Orc Marauders');
    expect(list.entries, [(name: 'Boyz', count: 20)]);
  });

  test('unrecognised text gives no list', () {
    for (final text in [
      '',
      'Intercessors x10\nCaptain',
      '+++ New Recruit +++\nBoyz [10] Q4+ D5+ | 200pts |',
      'GSC rising  (2000 Points)\n\nGenestealer Cults\n',
    ]) {
      expect(parseArmyList(text), isNull, reason: text);
    }
  });
}
