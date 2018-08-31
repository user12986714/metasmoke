# frozen_string_literal: true

class MetricsUpdateJob < ApplicationJob
  queue_as :default

  def perform(path, db_runtime)
    @logger ||= Logger.new(File.join(Rails.root, 'log', 'metrics_update_job_errors.log'))
    puts "Is sesnsible routes timing out?"
    route = Rails.sensible_routes.match_for path
    puts "Maybe!"
    return if route.nil?
    normalized_path = "#{route.verb} #{route.path}"
    Rails.logger.info "#{normalized_path} #{db_runtime}"

    query = QueryAverage.find_or_create_by(path: normalized_path)
    Rails.logger.info "BEFORE: #{query.counter} #{query.average}"
    query.average = (query.average * query.counter + db_runtime) / (query.counter += 1)
    query.save
    Rails.logger.info "AFTER: #{query.counter} #{query.average}"
  rescue => e
    puts e.message
    puts e.backtrace
    @logger.error e.message
    e.backtrace.each { |line| @logger.error line }
  end
end
