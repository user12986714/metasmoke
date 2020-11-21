# frozen_string_literal: true

class SearchController < ApplicationController
  def index
    # This might be ugly, but it's better than the alternative.
    #
    # And it's kinda clever.

    title, title_operation,
    body, body_operation,
    why, why_operation,
    username, username_operation = %i[title body why username].map do |s|
      SearchHelper.parse_search_params(params, s, current_user)
    end.flatten

    if [title_operation, body_operation, why_operation, username_operation].any?(&:!)
      render json: { error: 'Unauthenticated users cannot use regex search' }, status: 403
      return
    end

    user_reputation = params[:user_reputation].to_i || 0

    case params[:feedback]
    when /true/
      feedback = :is_tp
    when /false/
      feedback = :is_fp
    when /NAA/
      feedback = :is_naa
    end

    @results = if params[:reason].present?
                 Reason.find(params[:reason]).posts.includes_for_post_row
               else
                 Post.all.includes_for_post_row
               end

    per_page = user_signed_in? && params[:per_page].present? ? [params[:per_page].to_i, 10_000].min : 100

    search_string = []
    search_params = {}
    [[:username, username, username_operation], [:title, title, title_operation],
     [:body, body, body_operation], [:why, why, why_operation]].each do |si|
      if si[1].present? && si[1] != '%%'
        search_string << "IFNULL(`posts`.`#{si[0]}`, '') #{si[2]} :#{si[0]}"
        search_params[si[0]] = si[1]
      end
    end

    @results = @results.where(search_string.join(params[:or_search].present? ? ' OR ' : ' AND '), **search_params)
                       .paginate(page: params[:page], per_page: per_page)
                       .order(Arel.sql('`posts`.`created_at` DESC'))

    @results = @results.includes(:reasons).includes(:feedbacks) if params[:option].nil?

    if params[:has_no_feedback] == '1'
      @results = @results.joins('LEFT JOIN feedbacks fbcounter ON fbcounter.post_id = posts.id').where('fbcounter.id is null')
    end

    if feedback.present?
      @results = @results.where(feedback => true)
    elsif params[:feedback] == 'conflicted'
      @results = @results.where(is_tp: true, is_fp: true)
    end

    @results = case params[:user_rep_direction]
               when '>='
                 if user_reputation > 0
                   @results.where('IFNULL(user_reputation, 0) >= :rep', rep: user_reputation)
                 end
               when '=='
                 @results.where('IFNULL(user_reputation, 0) = :rep', rep: user_reputation)
               when '<='
                 @results.where('IFNULL(user_reputation, 0) <= :rep', rep: user_reputation)
               else
                 @results
               end

    @results = @results.where(site_id: params[:site]) if params[:site].present?

    @results = @results.where('revision_count > 1') if params[:edited].present?

    @results = @results.includes(feedbacks: [:user])

    case params[:autoflagged].try(:downcase)
    when 'yes'
      @results = @results.autoflagged
    when 'no'
      @results = @results.not_autoflagged
    end

    post_type = case params[:post_type].try(:downcase).try(:[], 0)
                when 'q'
                  'questions'
                when 'a'
                  'a'
                end

    if post_type.present?
      unmatched = @results.where.not("link LIKE '%/questions/%' OR link LIKE '%/a/%'")
      @results =  if params[:post_type_include_unmatched]
                    @results.where('link like ?', "%/#{post_type}/%").or(unmatched)
                  else
                    @results.where('link like ?', "%/#{post_type}/%")
                  end
    end

    respond_to do |format|
      format.html do
        @counts_by_accuracy_group = @results.group(:is_tp, :is_fp, :is_naa).count
        @counts_by_feedback = %i[is_tp is_fp is_naa].each_with_index.map do |symbol, i|
          [symbol, @counts_by_accuracy_group.select { |k, _v| k[i] }.values.sum]
        end.to_h

        case params[:feedback_filter]
        when 'tp'
          @results = @results.where(is_tp: true)
        when 'fp'
          @results = @results.where(is_fp: true)
        when 'naa'
          @results = @results.where(is_naa: true)
        end

        @sites = Site.where(id: @results.map(&:site_id)).to_a unless params[:option] == 'graphs'
        render :search
      end
      format.json do
        render json: @results
      end
      format.rss { render :search, layout: false }
      format.xml { render 'search.rss', layout: false }
    end
  end
end
