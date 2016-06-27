class Order < ActiveRecord::Base

  #when you hadd more reference types, be sure to add your accessors here
  attr_accessor :correlationid, :payerid, :token

  belongs_to :movie
  belongs_to :user
  has_many :ip_addresses
  has_many :paypals

  has_many :views

  belongs_to :bundle
  belongs_to :series
  belongs_to :coupon

  has_many :references, :class_name => "OrderReference"

  has_one :redeem_discount
  has_one :group_discount
  has_one :view

  scope :not_rejected, where("status not like '%rejected%'")
  scope :settled, where(:status => 'settled')
  scope :from_time_range, lambda { |time_range| where(:created_at => time_range) }
  scope :ordered_today, lambda {
    utc_today_midnight = Time.now.change(:hour => 0, :min => 0, :sec => 0)
    where("created_at > ?", utc_today_midnight)
  }
  scope :before, lambda { |date| where('created_at <= ?', date) }

  validates :movie_id, presence: true
  validates :unit_price, presence: true
  #validates_presence_of :movie_id, :unit_price

  before_validation :fill_in_unit_price, :tally_total_price

  after_create :set_flash_config_key, :series_pass_orders, :bundle_orders

  def fill_in_unit_price
    self.unit_price = self.movie.price_in_dollars || self.movie.fb_credits_to_dollars
  end

  def tally_total_price
    self.total_price = self.coupon ? (self.coupon.percent * 0.001 * self.movie.price) : self.unit_price
    self.total_price += self.tax_collected if self.tax_collected
  end


  def self.export_to_csv(orders = all)
    csv_string = CSV.generate do |csv|
      # header row
      csv << ["Rented at",
              "Facebook user",
              "Facebook order",
              "Status",
              "Total credits",
              "Total price",
              "Refund",
              "Tax Amount",
              "Zip Code"]

      orders.each do |order|
        csv << [order.rented_at,
                order.user.name,
                order.facebook_order_id,
                order.status,
                order.total_credits,
                order.total_price,
                order.status=='disputed' ? "Refund" : "",
                order.tax_collected,
                order.zip_code]
      end
    end

  end

  def pre_release?
    if movie.launch_date
      movie.launch_date > rented_at
    else
      false
    end
  end

  def touch_views
    if self.views.empty?
      View.create :order_id => self.id, :user_id => self.user_id
    else
      self.views.last
    end
  end


  def count_view
    View.create(:order_id => self.id, :movie_id => self.movie_id, :user_id => self.user_id)
  end


  def fb_popup_was_shown
    ie = IeIssue.find_by_movie_id_and_user_id movie_id, user_id
    ie.fb_popped_up? if ie
  end

  def log_ip(ip)
    ip_addresses.find_or_create_by_ip(ip)
  end

  def is_ip_ok?(ip)
    whitelisted_ips.include?(ip)
  end

  def expired?
    return false if status != 'settled'
    return true if movie.nil?
    expiration_time = rented_at + movie.rental_length.seconds
    expired = expiration_time < Time.now
    if !redeemed?
      #this order has not been redeemed
      false
    elsif redeemed? && !expired
      #this order has been redeemed and not expired
      false
    elsif redeemed? && expired
      #this order has been redeemed and has expired
      true
    end
  end

  def settle!
    update_attributes! :status => 'settled', :rented_at => Time.now.utc
    bundle_settle!
    series_settle!
  end

  def bundle_settle!
    if self.movie && self.movie.is_bundle?
      active_orders = movie.bundle.orders.where(:user_id => self.user_id, :status => "placed",
                                                :bundle_id => self.movie.bundle.id)
      active_paypal_orders = movie.bundle.orders.where(:user_id => self.user_id, :status => "pending",
                                                       :bundle_id => self.movie.bundle.id)
      active_orders.each do |order|
        order.update_attributes! :status => "settled", :rented_at => Time.now.utc
      end

      active_paypal_orders.each do |order|
        order.update_attributes! :status => "settled", :rented_at => Time.now.utc
      end
    end
  end

  def series_settle!
    if self.movie && self.movie.serial?
      active_orders = movie.series(true).orders.where(:user_id => self.user_id, :status => "placed",
                                                      :series_id => self.movie.series(true).id)
      active_paypal_orders = movie.series(true).orders.where(:user_id => self.user_id, :status => "pending",
                                                             :bundle_id => self.movie.series(true).id)
      active_orders.each do |order|
        order.update_attributes! :status => "settled", :rented_at => Time.now.utc
      end

      active_paypal_orders.each do |order|
        order.update_attributes! :status => "settled", :rented_at => Time.now.utc
      end
    end
  end


  def dispute!
    update_attributes! :status => 'disputed'
  end

  def refund!
    raise "Can only refund disputed orders" unless status == 'disputed'
    facebook_app = FbGraph::Application.new(movie.studio.facebook_app_id, :secret => movie.studio.facebook_app_secret)
    facebook_access_token = facebook_app.get_access_token
    fb_order = FbGraph::Order.new(facebook_order_id, :access_token => facebook_access_token)

    begin
      update_attributes! :status => 'refunded' if (@status = fb_order.refunded!(:message => "Refunding an order", :refund_funding_source => nil))
    rescue FbGraph::NotFound
    end

    raise "Failed to refund facebook order" unless @status == true
  end

  def self.process_from_fb_order(fb_order, coupon_code = nil)
    @coupon = Coupon.find_by_code coupon_code if coupon_code

    case fb_order.status
      when 'placed'
        movie = Movie.find_by_id(fb_order.movie_id)
        fb_user = User.find_by_facebook_user_id!(fb_order.user_id)

        FbCredit.create!(:user => fb_user,
                         :facebook_order_id => fb_order.order_id,
                         :status => fb_order.status,
                         :movie_id => fb_order.movie_id,
                         :total_credits => fb_order.total,
                         :zip_code => fb_order.zip_code,
                         :tax_collected => fb_order.tax_collected,
                         :coupon_id => @coupon.try(:id)
        )
      when 'settled'
        order = Order.find_by_facebook_order_id!(fb_order.order_id)
        order.coupon_id = @coupon.id if @coupon
        order.settle!
        false # we don't want our callback to return anything
      when 'disputed'
        order = Order.find_by_facebook_order_id!(fb_order.order_id)
        order.coupon_id = @coupon.id if @coupon
        order.dispute!
        false
    end
  end

  def set_flash_config_key
    update_attribute(:flash_config_key, KeyGenerator.generate)
  end

  def series_pass_orders
    movie = Movie.find(movie_id) if movie_id
    if movie
      if movie.serial?
        self.update_attribute(:series_id, movie.series(true).id)
        #if total_credits == movie.series(true).price
          movie.series(true).titles.each do |m|
            new_attributes = self.attributes.merge!("movie_id" => m.id, "series_id" => m.series.id)
            eval(self.type).create(new_attributes)
          end
        #end
      end
    end
  end

  def bundle_orders
    movie = Movie.find(movie_id) if movie_id
    if movie
      if movie.is_bundle?
        #if total_credits == movie.bundle.price
          movie.bundle.titles.each do |m|
            new_attributes = self.attributes.merge!("movie_id" => m.id, "bundle_id" => m.bundle.id)
            eval(self.type).create(new_attributes)
          end
        #end
      end
    end
  end

  private

  def ip_limit
    movie.studio.max_ips_for_movie
  end

  def whitelisted_ips
    ip_addresses.limit(ip_limit).map(&:ip)
  end

end

class Order::FacebookOrder
  attr_accessor :status, :user_id, :order_id, :movie_id, :total, :zip_code, :tax_collected, :coupon_code


  def initialize(order_details)
    @status = order_details['status'].try(:to_s)
    @order_id = order_details['order_id'].try(:to_s)
    @user_id = order_details['buyer'].try(:to_s)

    if @status == "placed"
      data = JSON.parse(order_details['items'].first['data'])

      @movie_id = data['movie_id']
      @total = data['cost'] + data['tax']
      @zip_code = data['zip_code']
      @tax_collected = data['tax']
    end
  end
end

# == Schema Information
#
# Table name: orders
#
#  id                :integer         not null, primary key
#  facebook_order_id :string(255)
#  status            :string(255)
#  created_at        :datetime        not null
#  updated_at        :datetime        not null
#  movie_id          :integer
#  rented_at         :datetime
#  total_credits     :integer
#  user_id           :integer
#  zip_code          :string(255)
#  tax_collected     :float
#  left_at           :integer
#  flash_config_key  :string(255)
#  bundle_id         :integer
#  total_price       :float
#  series_id         :integer
#  redeemed          :boolean
#  paid_with         :string(255)
#  coupon_id         :integer
#

