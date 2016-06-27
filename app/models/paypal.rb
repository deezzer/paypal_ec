class Paypal < Order
  require 'httparty'
  belongs_to :order

  PAYPAL_ENV = 'notlive'

  API_VERSION = '78.0'

  ENDPOINT = {
    production: 'https://api-3t.paypal.com/nvp?',
    sandbox: 'https://api-3t.sandbox.paypal.com/nvp?',
  }

  POPUP_ENDPOINT = {
    production: 'https://www.paypal.com/incontext?',
    sandbox: 'https://www.sandbox.paypal.com/incontext?'
  }

  CREDENTIALS = {
    sandbox: {
      USER: 'milyon_1311965754_biz_api1.gmail.com',
      PWD: '1311965791',
      SIGNATURE: 'FAKE.000.DaZWJMWW'
    },
    default: {
      USER: 'paypal_api1.movie.com',
      PWD: 'RSHPAYG4MSTTQ96B',
      SIGNATURE: 'FAKE.999'
    }
  }

  P_ENV = 'live'

  class << self
    # TODO: move all of this into a module or separate class

    # main payment request actions
    #   movie_info, initial_token, charge_transaction
    #
    def movie_info(token, studio)
      query = base_params(:GetExpressCheckoutDetails, studio).merge(TOKEN: token)
      response = Paypal.post(query)
      {:studio_id => response[:L_PAYMENTREQUEST_0_NUMBER0], :user_id => response[:PAYMENTREQUEST_0_CUSTOM]}
    end

    def initial_token(request, movie, user_id, tax = 0, coupon_price = nil)
      query = base_params(:SetExpressCheckout, movie.studio)
      query.merge! return_urls(movie, request)
      query.merge! order_params(movie, user_id, tax, coupon_price)

      response = Paypal.post(query)
      response[:TOKEN] || false
    end

    def charge_transaction(request, token, payer_id, order, user_id, coupon_price = nil)
      movie = order.movie
      query = base_params(:DoExpressCheckoutPayment, movie.studio)
      query.merge! return_urls(movie, request)
      query.merge! order_params(movie, user_id, movie.try(:vat).to_f, coupon_price)

      response = Paypal.post(query.merge(TOKEN: token, PAYERID: payer_id))

      if response[:ACK][/Success/]
        response_data = response.slice(:CORRELATIONID, :TOKEN, :PAYMENTINFO_0_PAYMENTSTATUS)
        settle_order(order, response_data.merge(:PAYERID => payer_id))
      else
        reject_order(order)
      end
    end

    # order param builders
    #
    def base_params(method, studio)
      credentials = if sandboxed?
        CREDENTIALS[:sandbox]
      elsif studio.paypal_credentials_present?
        studio.paypal_credentials
      else
        CREDENTIALS[:default]
      end
      credentials.merge(METHOD: method.to_s, VERSION: API_VERSION)
    end

    def order_params(movie, user_id, tax = 0, coupon_price = nil)
      price = price_select(movie, coupon_price)
      total = calculate_total(price, tax)

      order = build_order_details(movie, user_id, total, price, tax)
      item = build_item_details(price, movie.title, movie.id)

      order.merge(item)
    end

    def build_order_details(movie, user_id, total, item_amt, tax)
      {
        :PAYMENTREQUEST_0_DESC => URI.escape(movie.title),
        :PAYMENTREQUEST_0_AMT => total,
        :PAYMENTREQUEST_0_ITEMAMT => item_amt,
        :PAYMENTREQUEST_0_TAXAMT => tax,
        :PAYMENTREQUEST_0_PAYMENTACTION => 'Sale',
        :PAYMENTREQUEST_0_CURRENCYCODE => movie.studio.country_code?,
        :PAYMENTREQUEST_0_CUSTOM => user_id.to_s,
        :REQCONFIRMSHIPPING => '0',
        :NOSHIPPING => '1'

      }
    end

    def build_item_details(price, title, ref_id)
      {
        :L_PAYMENTREQUEST_0_AMT0 => formatted_amount(price),
        :L_PAYMENTREQUEST_0_NAME0 => URI.escape(title),
        :L_PAYMENTREQUEST_0_NUMBER0 => ref_id.to_s,
        :L_PAYMENTREQUEST_0_ITEMCATEGORY0 => 'Digital'
      }
    end

    def return_urls(movie, request, params={})
      base = url_extract(request)
      {
        :CANCELURL => url_setup(base, 'cancel', movie, params),
        :RETURNURL => url_setup(base, 'return', movie, params)
      }
    end

    def url_extract(request)
      Rails.env.development? ? "#{request.protocol}local.movie.net:#{request.port}" : request.protocol + request.host #("#{request.protocol}://#{request.host}")
    end

    def url_setup(base, endpoint, movie, params = {})
      default_params = { :studio_id => movie.studio_id, :ref => movie.class.name, :ref_id => movie.id }
      File.join(base, 'api', 'paypal', endpoint) + "?" + default_params.merge(params).to_query
    end

    # price calculuations
    #
    def price_select(movie, coupon_price = nil)
      price = coupon_price || movie.attributes['price_in_dollars'].presence || movie.price
      formatted_amount(price)
    end

    def calculate_total(price, tax = 0)
      price = tax.to_f.zero? ? price : (price.to_f + tax.to_f)
      formatted_amount(price)
    end

    # order handling
    #
    def settle_order(order, response_data)
      order.settle!
      OrderReference.create(order_id: order.id, kind: 'token', value: response_data[:TOKEN])
      OrderReference.create(order_id: order.id, kind: 'correlationid', value: response_data[:CORRELATIONID])
      OrderReference.create(order_id: order.id, kind: 'correlationid', value: response_data[:PAYERID])
      OrderReference.create(order_id: order.id, kind: 'correlationid', value: response_data[:PAYMENTINFO_0_PAYMENTSTATUS])
    end

    def reject_order(order)
      order.update_attribute(:status, 'rejected paypal')
    end

    # Util methods
    #
    def endpoint
      sandboxed? ? ENDPOINT[:sandbox] : ENDPOINT[:production]
    end

    def incontext_url(token)
      endpoint = sandboxed? ? POPUP_ENDPOINT[:sandbox] : POPUP_ENDPOINT[:production]
      endpoint + "token=#{token}"
    end

    def hasherize response
      Rack::Utils.parse_query(response).symbolize_keys!
    end

    def post query_hash
      response = HTTParty.get(endpoint + query_hash.to_query)
      hasherize(response.body)
    end

    def sandboxed?
      PAYPAL_ENV != 'live'
    end

    def formatted_amount(amt)
      "%.2f" % (amt.to_f)
    end
  end

  def settle(payerid)
    update_attributes!(status: 'settled', payerid: payerid)
  end


  def format_for(price)
    (price.to_f * 0.1)
  end

  def details(token)
    xml = Builder::XmlMarkup.new :indent => 2
    xml.tag! 'GetExpressCheckoutDetailsReq' do
      xml.tag! 'GetExpressCheckoutDetailsRequest' do
        xml.tag! 'Token', token
      end
    end
    xml.target!
  end
end
