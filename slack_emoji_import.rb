# frozen_string_literal: true

require 'esa'
require 'json'
require 'yaml'
require 'pp'

# Slack Emoji import to esa.io
# Using after export Slack Emoji: https://gist.github.com/masutaka/057a7a4a1b4bbb4320b73dcb59bc7705
class EmojiImporter

  def initialize(esa_client)
    @client = esa_client
    puts 'initialize'
  end

  attr_accessor :client

  def import(dry_run: true, start_index: 0)
    codes = Dir.glob('*', base: './images').sort
    image_files = Dir.glob('./images/*').sort

    codes.each_with_index do |code, index|
      next if index < start_index

      image_file = image_files[index]

      if dry_run
        puts "##{index}\t#{code}\t#{image_file}"
        next
      end

      print "[#{Time.now}] index[#{index}] code: #{code} => "
      response = client.create_emoji(code: code, image: image_file)

      case response.status
      when 200, 201
        puts "created: #{response.body['code']}"
      when 400
        # BadRequest: 重複と日本語キーワードでの登録は無視する
        puts "#{response.body['message']}"
        next
      when 429
        retry_after = (response.headers['Retry-After'] || 20 * 60).to_i
        puts "rate limit exceeded: will retry after #{retry_after} seconds."
        wait_for(retry_after)
        redo
      else
        puts "failure with status: #{response.status}, #{response.body}"
        exit 1
      end
    end
  end

  private

  def wait_for(seconds)
    (seconds / 10).times do
      print '.'
      sleep 10
    end
    puts
  end
end

esa_client = Esa::Client.new(
  access_token: ENV['ESA_ACCESS_TOKEN'],
  current_team: ENV['ESA_CURRENT_TEAM']
)

importer = EmojiImporter.new(esa_client)
importer.import # default: dry_run
