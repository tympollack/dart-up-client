#!/usr/bin/env python3
"""
Procedural Tech Tree Generator
================================
Reads a static "Fog of War" tech tree dataset (5 Macro-Tech win-condition
nodes + 20 Micro-Tech nodes spread across 5 disciplines) and procedurally
wires up prerequisite pathways for a single game Era.

Design rules enforced by this generator:
  1. Within a discipline, Tier-2 nodes always require 1+ Tier-1 nodes
     from that SAME discipline (the "obvious" path).
  2. Each Tier-2 node has a chance to ALSO require a Tier-1 node from a
     DIFFERENT discipline -- this is what produces "intersecting
     pathways" rather than five isolated, parallel ladders.
  3. Every Macro-Tech requires nodes from at least `min_disciplines`
     (default 3) distinct disciplines, preferring the more advanced
     Tier-2 node in each chosen discipline as the actual gate.
  4. The resulting graph is validated to be acyclic and to satisfy rule 3
     before being written out.

Output: a flat {nodes, edges} graph that any front-end (D3, Cytoscape,
a custom canvas renderer, etc.) can consume directly to draw a node map.
Each node already carries its `discipline` and `tier`, so a front end can
lay out disciplines as parallel lanes and tiers as columns without any
extra lookups.
"""

import json
import random
import argparse
from collections import defaultdict
from datetime import datetime, timezone


def load_data(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def group_by_discipline(micro_techs):
    groups = defaultdict(list)
    for node in micro_techs:
        groups[node["discipline"]].append(node)
    return groups


def generate_intra_discipline_edges(by_discipline, rng, cross_link_chance=0.4):
    """
    Wires Tier-1 -> Tier-2 prerequisites inside each discipline, then
    rolls a chance for each Tier-2 node to ALSO require a Tier-1 node
    from a different discipline. That second roll is what produces the
    'intersecting pathways' the brief asks for -- a player chasing
    Plasma Conduits might suddenly need a dash of Cybernetics too.
    """
    edges = []
    disciplines = sorted(by_discipline.keys())

    for discipline, nodes in by_discipline.items():
        tier1 = [n for n in nodes if n["tier"] == 1]
        tier2 = [n for n in nodes if n["tier"] == 2]

        for t2_node in tier2:
            if not tier1:
                continue
            num_reqs = rng.randint(1, len(tier1))
            reqs = rng.sample(tier1, num_reqs)
            for req in reqs:
                edges.append({
                    "source": req["id"],
                    "target": t2_node["id"],
                    "type": "prerequisite",
                })

            if rng.random() < cross_link_chance:
                other_disciplines = [d for d in disciplines if d != discipline]
                if other_disciplines:
                    foreign_discipline = rng.choice(other_disciplines)
                    foreign_tier1 = [
                        n for n in by_discipline[foreign_discipline] if n["tier"] == 1
                    ]
                    if foreign_tier1:
                        foreign_node = rng.choice(foreign_tier1)
                        edges.append({
                            "source": foreign_node["id"],
                            "target": t2_node["id"],
                            "type": "cross-discipline",
                        })
    return edges


def generate_macro_requirements(macro_techs, by_discipline, rng, min_disciplines=3):
    """
    Guarantees every Macro-Tech requires Micro-Techs from at least
    `min_disciplines` distinct disciplines, preferring the Tier-2 node
    from each chosen discipline as the actual gate (falling back to
    Tier-1 only if a discipline has no Tier-2 node).
    """
    edges = []
    disciplines = sorted(by_discipline.keys())

    for macro in macro_techs:
        k = rng.randint(min_disciplines, len(disciplines))
        chosen_disciplines = rng.sample(disciplines, k)

        for discipline in chosen_disciplines:
            candidates = by_discipline[discipline]
            tier2_candidates = [n for n in candidates if n["tier"] == 2]
            pool = tier2_candidates if tier2_candidates else candidates
            chosen_node = rng.choice(pool)
            edges.append({
                "source": chosen_node["id"],
                "target": macro["id"],
                "type": "macro-unlock",
            })
    return edges


def validate_graph(nodes_by_id, edges, macro_ids, min_disciplines=3):
    """Sanity-check pass. Raises AssertionError on a malformed tree."""
    macro_inputs = defaultdict(set)
    for edge in edges:
        if edge["target"] in macro_ids:
            src_node = nodes_by_id[edge["source"]]
            macro_inputs[edge["target"]].add(src_node["discipline"])

    for macro_id in macro_ids:
        disciplines_covered = macro_inputs.get(macro_id, set())
        assert len(disciplines_covered) >= min_disciplines, (
            f"{macro_id} only pulls from {len(disciplines_covered)} "
            f"disciplines, needs >= {min_disciplines}"
        )

    # The graph is acyclic by construction (Tier1 -> Tier2 -> Macro is
    # strictly one-directional), but verify defensively in case the
    # dataset changes shape later.
    adjacency = defaultdict(list)
    for edge in edges:
        adjacency[edge["source"]].append(edge["target"])

    visiting, visited = set(), set()

    def has_cycle(node_id):
        if node_id in visiting:
            return True
        if node_id in visited:
            return False
        visiting.add(node_id)
        for neighbor in adjacency[node_id]:
            if has_cycle(neighbor):
                return True
        visiting.remove(node_id)
        visited.add(node_id)
        return False

    for node_id in nodes_by_id:
        assert not has_cycle(node_id), f"Cycle detected through {node_id}"


def build_tech_tree(data, seed=None, min_disciplines=3, cross_link_chance=0.4):
    rng = random.Random(seed)

    micro_techs = data["microTechs"]
    macro_techs = data["macroTechs"]
    by_discipline = group_by_discipline(micro_techs)

    edges = []
    edges += generate_intra_discipline_edges(by_discipline, rng, cross_link_chance)
    edges += generate_macro_requirements(macro_techs, by_discipline, rng, min_disciplines)

    # De-dupe in case randomness produced the same edge twice.
    seen = set()
    unique_edges = []
    for e in edges:
        key = (e["source"], e["target"], e["type"])
        if key not in seen:
            seen.add(key)
            unique_edges.append(e)

    nodes_out = (
        [{**n, "nodeType": "micro"} for n in micro_techs]
        + [{**m, "nodeType": "macro"} for m in macro_techs]
    )
    nodes_by_id = {n["id"]: n for n in nodes_out}
    macro_ids = {m["id"] for m in macro_techs}

    validate_graph(nodes_by_id, unique_edges, macro_ids, min_disciplines)

    return {
        "nodes": nodes_out,
        "edges": unique_edges,
        "meta": {
            "seed": seed,
            "minDisciplinesPerMacro": min_disciplines,
            "crossLinkChance": cross_link_chance,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "nodeCount": len(nodes_out),
            "edgeCount": len(unique_edges),
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Generate a procedural Era tech tree.")
    parser.add_argument("--input", default="tech_tree_data.json")
    parser.add_argument("--output", default="generated_tech_tree.json")
    parser.add_argument(
        "--seed", type=int, default=None,
        help="Era seed; same seed always reproduces the same tree. Omit for a fresh random tree.",
    )
    parser.add_argument("--min-disciplines", type=int, default=3)
    parser.add_argument("--cross-link-chance", type=float, default=0.4)
    args = parser.parse_args()

    data = load_data(args.input)
    tree = build_tech_tree(
        data,
        seed=args.seed,
        min_disciplines=args.min_disciplines,
        cross_link_chance=args.cross_link_chance,
    )

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(tree, f, indent=2)

    print(f"Generated {tree['meta']['nodeCount']} nodes / {tree['meta']['edgeCount']} edges")
    print(f"Seed: {tree['meta']['seed']}")
    print(f"Written to {args.output}")


if __name__ == "__main__":
    main()
