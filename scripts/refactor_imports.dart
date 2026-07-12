import 'dart:io';

void main() {
  final fileMap = {
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
  };

  final libDir = Directory('../lib');
  
  if (!libDir.existsSync()) {
    print('lib directory not found');
    return;
  }

  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      var content = entity.readAsStringSync();
      var newContent = content;

      for (final entry in fileMap.entries) {
        final dartFile = entry.key;
        final domain = entry.value;

        // Replace simple relative imports
        final pattern1 = RegExp("import\\s+['\"]" + RegExp.escape(dartFile) + "['\"]");
        newContent = newContent.replaceAll(pattern1, "import 'package:sd_client/$domain/$dartFile'");
        
        // Replace package imports
        final pattern2 = RegExp("import\\s+['\"]package:sd_client/" + RegExp.escape(dartFile) + "['\"]");
        newContent = newContent.replaceAll(pattern2, "import 'package:sd_client/$domain/$dartFile'");
        
        // Replace relative imports with ./ or ../
        final pattern3 = RegExp("import\\s+['\"](?:\\./|\\.\\./)+" + RegExp.escape(dartFile) + "['\"]");
        newContent = newContent.replaceAll(pattern3, "import 'package:sd_client/$domain/$dartFile'");
      }

      if (content != newContent) {
        entity.writeAsStringSync(newContent);
        print('Updated ${entity.path}');
      }
    }
  }
}
