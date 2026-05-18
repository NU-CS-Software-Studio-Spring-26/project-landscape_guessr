class EnablePostgis < ActiveRecord::Migration[8.1]
  def up
    enable_extension "postgis" if postgis_available?
  end

  def down
    disable_extension "postgis" if postgis_available?
  end

  private

  def postgis_available?
    result = execute("SELECT 1 FROM pg_available_extensions WHERE name = 'postgis'")
    result.any?
  rescue
    false
  end
end
