defmodule Aces.Repo.Migrations.AddPilotCheckConstraints do
  use Ecto.Migration

  def change do
    # Add check constraints for data integrity
    create constraint(:pilots, :valid_skill_level, 
      check: "skill_level >= 0 AND skill_level <= 10")
    
    create constraint(:pilots, :valid_wounds, 
      check: "wounds >= 0")
    
    create constraint(:pilots, :valid_sp_earned, 
      check: "sp_earned >= 0")
    
    create constraint(:pilots, :valid_edge_tokens, 
      check: "edge_tokens >= 0")
    
    create constraint(:pilots, :valid_mvp_awards, 
      check: "mvp_awards >= 0")
    
    create constraint(:pilots, :valid_sorties_participated, 
      check: "sorties_participated >= 0")
    
    create constraint(:pilots, :valid_status, 
      check: "status IN ('active', 'wounded', 'deceased')")
  end
end