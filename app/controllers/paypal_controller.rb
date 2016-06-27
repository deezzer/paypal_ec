class Api::PaypalController < ApplicationController
  skip_before_filter :validate_geo_restriction
  before_filter :load_movie

  def return
    paypal = Paypal.movie_info(params[:token], studio)

    order_details = { :movie_id => @movie.id, :status => 'pending', :user_id => paypal[:user_id] }

    price = if @movie.is_bundle?
      @movie.bundle.fb_credts_to_dollars
    elsif @movie.serial?
      @movie.series(true).fb_credits_to_dollars
    end

    order_details.merge!(:price_in_dollars => price) if price

    order = Paypal.create(order_details)

    Paypal.charge_transaction(request, params[:token], params[:PayerID], order, order.user_id)

    @dialog = {:show_facebook_feed_dialog => true}
    render :paypal, :layout => false
  end

  def cancel
    render :paypal, :layout => false
  end

  private
  def load_movie
    @movie = Movie.find(params[:ref_id])
  end
end
