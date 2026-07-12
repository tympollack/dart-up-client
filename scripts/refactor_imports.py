import os
import re

file_map = {
    'main.dart': 'core',
    'main_game.dart': 'core',
    'main_mvp.dart': 'core',
    'dart_up_game.dart': 'core',
    
    'celestial_node_component.dart': 'celestial',
    'celestial_node_manager.dart': 'celestial',
    
    'combat_manager.dart': 'combat',
    'combat_vfx_component.dart': 'combat',
    'enemy_director.dart': 'combat',
    'enemy_fighter_render_component.dart': 'combat',
    'fighter_roster.dart': 'combat',
    
    'bugger_swarm.dart': 'swarm',
    'drone_swarm_economy.dart': 'swarm',
    'swarm_isolate.dart': 'swarm',
    'swarm_manager.dart': 'swarm',
    'swarm_render_component.dart': 'swarm',
    
    'hacking_controller.dart': 'player',
    'hacking_ui_component.dart': 'player',
    'player_ship_component.dart': 'player',
    'ship_warp_controller.dart': 'player',
    'warp_wake_tracking.dart': 'player',
}

lib_dir = os.path.join(os.path.dirname(__file__), '..', 'lib')

for root, _, files in os.walk(lib_dir):
    for filename in files:
        if filename.endswith('.dart'):
            filepath = os.path.join(root, filename)
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
                
            new_content = content
            for dart_file, domain in file_map.items():
                # Replace simple relative imports
                pattern1 = r"import\s+['\"]" + re.escape(dart_file) + r"['\"]"
                repl1 = f"import 'package:sd_client/{domain}/{dart_file}'"
                new_content = re.sub(pattern1, repl1, new_content)
                
                # Replace package imports
                pattern2 = r"import\s+['\"]package:sd_client/" + re.escape(dart_file) + r"['\"]"
                repl2 = f"import 'package:sd_client/{domain}/{dart_file}'"
                new_content = re.sub(pattern2, repl2, new_content)
                
                # Replace relative imports with ./ or ../
                pattern3 = r"import\s+['\"](?:./|\.\./)+" + re.escape(dart_file) + r"['\"]"
                repl3 = f"import 'package:sd_client/{domain}/{dart_file}'"
                new_content = re.sub(pattern3, repl3, new_content)
                
            if new_content != content:
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                print(f"Updated {filename}")
