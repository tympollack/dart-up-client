// =============================================================================
// procedural_era_tech_tree.dart
//
// Seed-deterministic procedural generator producing an acyclic DAG tech tree
// across the 5 core Era disciplines (`Energy`, `Materials`, `Cybernetics`,
// `Xenobiology`, `Logistics`).
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:math' as math;

/// The 5 core research disciplines in an Era.
enum TechDiscipline {
  energy('Energy'),
  materials('Materials'),
  cybernetics('Cybernetics'),
  xenobiology('Xenobiology'),
  logistics('Logistics');

  final String label;
  const TechDiscipline(this.label);
}

/// Immutable node inside a procedurally generated Era Tech Tree DAG.
class EraTechNode {
  final String id;
  final String name;
  final TechDiscipline discipline;
  final int tier;
  final double researchCost;

  /// IDs of prerequisite tech nodes that must be unlocked prior to this node.
  /// Strictly references nodes with `tier < this.tier`, guaranteeing an acyclic DAG.
  final List<String> prerequisiteIds;

  /// Deterministic stat modifiers unlocked by researching this node.
  final Map<String, double> statModifiers;

  const EraTechNode({
    required this.id,
    required this.name,
    required this.discipline,
    required this.tier,
    required this.researchCost,
    required this.prerequisiteIds,
    required this.statModifiers,
  });
}

/// Deterministic, seed-based acyclic DAG tech tree across the 5 Era disciplines.
class ProceduralEraTechTree {
  final int eraSeed;
  final int tiersPerDiscipline;
  final List<EraTechNode> nodes;
  late final Map<String, EraTechNode> _nodesById;

  ProceduralEraTechTree._({
    required this.eraSeed,
    required this.tiersPerDiscipline,
    required List<EraTechNode> nodes,
  }) : nodes = List.unmodifiable(nodes) {
    _nodesById = {for (final n in this.nodes) n.id: n};
  }

  /// Deterministically generates an acyclic 5-discipline tech DAG from [eraSeed].
  factory ProceduralEraTechTree.generate({
    required int eraSeed,
    int tiersPerDiscipline = 4,
  }) {
    assert(tiersPerDiscipline >= 2);
    final rng = math.Random(eraSeed);
    final generated = <EraTechNode>[];
    final byTier = <int, List<EraTechNode>>{};

    for (int tier = 0; tier < tiersPerDiscipline; tier++) {
      final tierList = <EraTechNode>[];
      for (final discipline in TechDiscipline.values) {
        final id = '${discipline.name}_t$tier';
        final costBase = 100.0 * math.pow(1.85, tier);
        final costJitter = (0.85 + rng.nextDouble() * 0.30);
        final researchCost = (costBase * costJitter).roundToDouble();

        final prereqs = <String>[];
        if (tier > 0) {
          // Always require the previous tier in the same discipline
          prereqs.add('${discipline.name}_t${tier - 1}');

          // Seed-driven cross-discipline synergy edge from tier - 1
          final prevTierNodes = byTier[tier - 1]!;
          if (rng.nextDouble() < 0.55) {
            final crossCandidate =
                prevTierNodes[rng.nextInt(prevTierNodes.length)];
            if (!prereqs.contains(crossCandidate.id)) {
              prereqs.add(crossCandidate.id);
            }
          }
        }

        final boostValue =
            double.parse(((0.08 * (tier + 1)) + rng.nextDouble() * 0.07).toStringAsFixed(3));
        final node = EraTechNode(
          id: id,
          name: '${discipline.label} Tier $tier Protocol',
          discipline: discipline,
          tier: tier,
          researchCost: researchCost,
          prerequisiteIds: List.unmodifiable(prereqs),
          statModifiers: Map.unmodifiable({
            '${discipline.name}_efficiency': boostValue,
          }),
        );

        tierList.add(node);
        generated.add(node);
      }
      byTier[tier] = tierList;
    }

    return ProceduralEraTechTree._(
      eraSeed: eraSeed,
      tiersPerDiscipline: tiersPerDiscipline,
      nodes: generated,
    );
  }

  EraTechNode? nodeById(String id) => _nodesById[id];

  List<EraTechNode> nodesForDiscipline(TechDiscipline discipline) =>
      nodes.where((n) => n.discipline == discipline).toList(growable: false);

  /// Verifies that the tech tree is a valid Directed Acyclic Graph (zero cycles)
  /// using Kahn's topological sort / DFS cycle check.
  bool isAcyclic() {
    final visited = <String, int>{}; // 0 = unvisited, 1 = visiting, 2 = visited

    bool dfs(String nodeId) {
      final state = visited[nodeId] ?? 0;
      if (state == 1) return false; // Cycle detected!
      if (state == 2) return true;

      visited[nodeId] = 1;
      final node = _nodesById[nodeId];
      if (node != null) {
        for (final prereqId in node.prerequisiteIds) {
          if (!dfs(prereqId)) return false;
        }
      }
      visited[nodeId] = 2;
      return true;
    }

    for (final node in nodes) {
      if (!dfs(node.id)) return false;
    }
    return true;
  }

  /// Checks whether [nodeId] can be researched given [unlockedNodeIds].
  bool canResearch(String nodeId, Set<String> unlockedNodeIds) {
    if (unlockedNodeIds.contains(nodeId)) return false;
    final node = _nodesById[nodeId];
    if (node == null) return false;
    for (final req in node.prerequisiteIds) {
      if (!unlockedNodeIds.contains(req)) return false;
    }
    return true;
  }

  /// Structural equality check for deterministic seed verification.
  bool equalsTree(ProceduralEraTechTree other) {
    if (nodes.length != other.nodes.length) return false;
    for (int i = 0; i < nodes.length; i++) {
      final a = nodes[i];
      final b = other.nodes[i];
      if (a.id != b.id ||
          a.discipline != b.discipline ||
          a.tier != b.tier ||
          a.researchCost != b.researchCost ||
          a.prerequisiteIds.join(',') != b.prerequisiteIds.join(',')) {
        return false;
      }
    }
    return true;
  }
}
