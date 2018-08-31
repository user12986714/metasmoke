# frozen_string_literal: true

class MetricsUpdateJob < ApplicationJob
  queue_as :default

  def perform(path, db_runtime)
    @logger ||= Logger.new(File.join(Rails.root, 'log', 'metrics_update_job_errors.log'))
    puts "Is sesnsible routes timing out?"
    route = Rails.sensible_routes.match_for path
    puts "Checkpoint 1"
    return if route.nil?
    normalized_path = "#{route.verb} #{route.path}"
    puts "Checkpoint 2"
    Rails.logger.info "#{normalized_path} #{db_runtime}"

    query = QueryAverage.find_or_create_by(path: normalized_path)
    puts "Checkpoint 3"
    Rails.logger.info "BEFORE: #{query.counter} #{query.average}"
    query.average = (query.average * query.counter + db_runtime) / (query.counter += 1)
    puts "Checkpoint 4"
    query.save
    puts "Checkpoint 5"
    Rails.logger.info "AFTER: #{query.counter} #{query.average}"
    puts "Exited! (no error)"
  rescue => e
    puts e.message
    puts e.backtrace
    @logger.error e.message
    e.backtrace.each { |line| @logger.error line }
    puts "Exited! (error)"
  end
end
