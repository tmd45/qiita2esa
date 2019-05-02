# frozen_string_literal: true

require 'qiita'
require 'json'
require 'pp'

# Export from Qiita:Team
class Exporter
  MAX_PER_PAGE = 100

  # @param qiita_client [Qiita::Client]
  # @param qiita_export_file_path [String]
  def initialize(qiita_client)
    @client = qiita_client
    @data_dir = ENV['DATA_DIR']
    @filename_prefix = ENV['QIITA_EXPORT_FILENAME_PREFIX']
    @filename_suffix = ENV['QIITA_EXPORT_FILENAME_SUFFIX']
    puts 'initialize'
  end

  attr_accessor :client, :data_dir, :filename_prefix, :filename_suffix

  def export
    # get Qiita:Team Projects Data
    projects = client.list_projects(per_page: MAX_PER_PAGE)
    exit 1 unless projects.status == 200

    projects_filepath = filepath(target: 'projects')
    File.open(projects_filepath, 'w') do |file|
      JSON.dump(projects.body, file)
    end
    puts 'export!'
  end

  private

  # create file path
  #
  # @param target [String] 'projects', 'articles', etc.
  def filepath(target: nil)
    File.path(data_dir + filename_prefix + target + filename_suffix)
  end
end

qiita_client = Qiita::Client.new(
  access_token: ENV['QIITA_ACCESS_TOKEN'],
  team: ENV['QIITA_CURRENT_TEAM']
)

exporter = Exporter.new(qiita_client)
exporter.export
