require 'spec_helper'

describe Paypal do
  let(:movie) {FactoryGirl.create(:movie)}
  let(:user) { FactoryGirl.create(:user) }
  let(:request) { mock(Rack::Request, :protocol => 'https://', :host => 'fake.heroku.com', :port => '3000') }

  it "should have a valid factory" do
    paypal = FactoryGirl.create(:paypal)
    paypal.should be_valid
  end

  describe "checkout process" do
    let(:studio) { FactoryGirl.create(:studio, id: 1, :vat => 0) }
    let(:movie) { FactoryGirl.create(:movie, {id: 1, title: "a random movie", price_in_dollars: "5.00", studio: studio})}
    let(:user) { FactoryGirl.create(:user, id: 1) }
    let(:token) { "EC-72J93926X37469332" }

    describe ".initial_token" do
      it 'returns the initial_token on success' do
        VCR.use_cassette 'paypal/set_express_checkout_success', :record => :none do
          response = Paypal.initial_token(request, movie, user.id)
          response.should == token
        end
      end
    end

    describe ".get_express_checkout_details" do
      it 'returns the movie id from the order' do
        VCR.use_cassette 'paypal/get_express_checkout_details_success', :record => :none do
          response = Paypal.movie_info(token, studio.id)
          response.should == {:studio_id => studio.id.to_s, :user_id => user.id.to_s}
        end
      end
    end

    describe ".do_express_checkout_payment" do
      let!(:order) { FactoryGirl.create(:paypal, user: user, movie: movie) }
      let(:payer_id) { "1234" }
      it 'sends a request to paypal and charges the transaction' do
        VCR.use_cassette 'paypal/do_express_checkout_payment', :record => :none do
          response = Paypal.charge_transaction(request, token, payer_id, order, user.id)
          # need test for response without return value
        end
      end
    end
  end

  describe ".order_params" do
    let(:movie) { FactoryGirl.create(:movie, title: "Toy Story", price_in_dollars: "10.00") }

    it 'returns a hash of order parameters' do
      Paypal.order_params(movie, user.id, 0, nil).should == {
        :PAYMENTREQUEST_0_DESC => "Toy%20Story",
        :PAYMENTREQUEST_0_AMT => "10.00",
        :PAYMENTREQUEST_0_ITEMAMT => "10.00",
        :PAYMENTREQUEST_0_TAXAMT => 0,
        :PAYMENTREQUEST_0_PAYMENTACTION => "Sale",
        :PAYMENTREQUEST_0_CURRENCYCODE => "USD",
        :PAYMENTREQUEST_0_CUSTOM => user.id.to_s,
        :REQCONFIRMSHIPPING => "0",
        :NOSHIPPING => "1",
        :L_PAYMENTREQUEST_0_AMT0 => "10.00",
        :L_PAYMENTREQUEST_0_NAME0 => "Toy%20Story",
        :L_PAYMENTREQUEST_0_NUMBER0 => movie.id.to_s,
        :L_PAYMENTREQUEST_0_ITEMCATEGORY0 => "Digital"
      }
    end
  end

  describe ".price_select" do
    context 'with a movie that has a price_in_dollars' do
      let(:movie) { FactoryGirl.create(:movie, price_in_dollars: "10.00") }
      it { Paypal.price_select(movie).should == "10.00" }
    end

    context 'with a movie with no price_in_dollars and given coupon price' do
      let(:movie) { FactoryGirl.create(:movie, price_in_dollars: nil) }
      it { Paypal.price_select(@movie, "1.00").should == "1.00" }
    end

    context "with a movie with no price_in_dollars, no coupon price, and with movie price" do
      let(:movie) { FactoryGirl.create(:movie, price: "10.00") }
      it { Paypal.price_select(movie).should == "10.00" }
    end
  end

  describe ".calculate_total" do
    context "no tax" do
      it "returns the untouched price" do
        Paypal.calculate_total("5.00", 0).should == "5.00"
      end
    end

    context "with tax" do
      it "returns the calculated total with tax" do
        Paypal.calculate_total("5.00", "2.00").should == "7.00"
        Paypal.calculate_total("10.00", "0.50").should == "10.50"
      end
    end
  end

  describe ".build_order_details" do
    let(:studio) { FactoryGirl.create(:studio, country_code: "USD")}
    let(:movie) { FactoryGirl.create(:movie, title: 'Transformers 3', studio: studio) }

    it 'builds the order detail params for the order' do
      order_details = Paypal.build_order_details(movie, user.id, "10.00", "5.00", "1.00")
      order_details.should == {
        :PAYMENTREQUEST_0_DESC => "Transformers%203",
        :PAYMENTREQUEST_0_AMT => "10.00",
        :PAYMENTREQUEST_0_ITEMAMT => "5.00",
        :PAYMENTREQUEST_0_TAXAMT => "1.00",
        :PAYMENTREQUEST_0_PAYMENTACTION => 'Sale',
        :PAYMENTREQUEST_0_CURRENCYCODE => studio.country_code?,
        :PAYMENTREQUEST_0_CUSTOM => user.id.to_s,
        :REQCONFIRMSHIPPING => '0',
        :NOSHIPPING => '1'
      }
    end
  end

  describe ".build_item_details" do
    let(:movie) {FactoryGirl.create(:movie, title: 'Transformers 3') }

    it 'builds the item params for the order' do
      item = Paypal.build_item_details(10, movie.title, movie.id)
      item.should == {
        :L_PAYMENTREQUEST_0_AMT0 => "10.00",
        :L_PAYMENTREQUEST_0_NAME0 => "Transformers%203",
        :L_PAYMENTREQUEST_0_NUMBER0 => movie.id.to_s,
        :L_PAYMENTREQUEST_0_ITEMCATEGORY0 => "Digital"
      }
    end
  end

  describe ".base_params" do
    context "when sandboxed" do
      let(:studio) { FactoryGirl.create(:studio) }

      it 'returns the sandbox credentials' do
        Paypal.stub(:sandboxed?).and_return(true)
        base_params = Paypal.base_params(:blah, studio)
        base_params.should == Paypal::CREDENTIALS[:sandbox].merge(:METHOD => 'blah', :VERSION => Paypal::API_VERSION)
      end
    end

    context "when not sandboxed" do
      let(:studio1) { FactoryGirl.create(:studio, paypal_api_user: 'user', paypal_api_password: 'pwd', paypal_api_signature: '123') }
      let(:studio2) { FactoryGirl.create(:studio, paypal_api_user: nil, paypal_api_password: nil, paypal_api_signature: nil) }

      it 'returns the studio credentials if present' do
        Paypal.stub(:sandboxed?).and_return(false)
        base_params = Paypal.base_params(:blah, studio1)
        base_params.should == {
          :USER => 'user',
          :PWD => 'pwd',
          :SIGNATURE => '123',
          :METHOD => 'blah',
          :VERSION => Paypal::API_VERSION
        }
      end

      it 'returns the default credentials if studio credentials are not present' do
        Paypal.stub(:sandboxed?).and_return(false)
        base_params = Paypal.base_params(:blah, studio2)
        base_params.should == Paypal::CREDENTIALS[:default].merge(:METHOD => 'blah', :VERSION => Paypal::API_VERSION)
      end
    end
  end

  describe ".settle_order" do
    let!(:order) { FactoryGirl.create(:order) }
    let!(:response_data) { {:CORRELATIONID => '1', :TOKEN => 'token', :PAYERID => '1', :PAYMENTINFO_0_PAYMENTSTATUS => 'settled' } }

    it 'settles the order' do
      order.should_receive(:settle!).once
      Paypal.settle_order(order, response_data)
    end

    it 'creates order references' do
      OrderReference.should_receive(:create).exactly(4).times
      Paypal.settle_order(order, response_data)
    end

    it 'creates order references' do
      expect {
        Paypal.settle_order(order, response_data)
      }.to change(OrderReference, :count).by(4)
    end
  end

  describe ".reject_order" do
    it 'sets order status to rejected' do
      order = FactoryGirl.create(:order, :status => 'blah')
      Paypal.reject_order(order)
      order.reload.status.should == 'rejected paypal'
    end
  end

  describe ".endpoint" do
    context 'when in sandbox mode' do
      it 'returns the sandbox endpoint' do
        Paypal.stub(:sandboxed?).and_return(true)
        Paypal.endpoint.should == 'https://api-3t.sandbox.paypal.com/nvp?'
      end
    end

    context 'when not in sandbox mode' do
      it 'returns the production endpoint' do
        Paypal.stub(:sandboxed?).and_return(false)
        Paypal.endpoint.should == 'https://api-3t.paypal.com/nvp?'
      end
    end
  end

  describe ".incontext_url" do
    let(:token) { "token" }

    context 'when sandboxed' do
      it 'returns the sandbox popup_endpoint url' do
        Paypal.stub(:sandboxed? => true)
        Paypal.incontext_url(token).should == Paypal::POPUP_ENDPOINT[:sandbox] + "token=#{token}"
      end
    end

    context 'when not sandboxed' do
      it 'returns the production popup_endpoint url' do
        Paypal.stub(:sandboxed? => false)
        Paypal.incontext_url(token).should == Paypal::POPUP_ENDPOINT[:production] + "token=#{token}"
      end
    end
  end

  describe ".hasherize" do
    it 'returns a hash from a query string' do
      query = "foo=bar&beep=boop"
      Paypal.hasherize(query).should == {
        :foo => "bar",
        :beep => "boop"
      }
    end
  end

  describe ".return_urls" do
    context 'when in development mode' do
      it 'should_return the proper urls' do
        Rails.env.stub(:development?).and_return(false)
        Paypal.return_urls(movie, request).should == {
          CANCELURL: "https://fake.heroku.com/api/paypal/cancel?ref=Movie&ref_id=#{movie.id}&studio_id=#{movie.studio_id}",
          RETURNURL: "https://fake.heroku.com/api/paypal/return?ref=Movie&ref_id=#{movie.id}&studio_id=#{movie.studio_id}"
        }
      end
    end

    context 'when not in development mode' do
      it 'should_return the proper urls' do
        Rails.env.stub(:development?).and_return(true)
        Paypal.return_urls(movie, request).should == {
          CANCELURL: "https://local.movie.net:3000/api/paypal/cancel?ref=Movie&ref_id=#{movie.id}&studio_id=#{movie.studio_id}",
          RETURNURL: "https://local.movie.net:3000/api/paypal/return?ref=Movie&ref_id=#{movie.id}&studio_id=#{movie.studio_id}"
        }
      end
    end
  end

  describe ".url_extract" do
    it 'returns the local base_url when in development mode' do
      Rails.env.stub(:development?).and_return(true)
      Paypal.url_extract(request).should == "https://local.movie.net:3000"
    end

    it 'returns the base_url of the request when not in dev mode' do
      Rails.env.stub(:development?).and_return(false)
      Paypal.url_extract(request).should == "https://fake.heroku.com"
    end
  end

  describe ".url_setup" do
    let(:studio) { FactoryGirl.create(:studio) }
    let(:movie) { FactoryGirl.create(:movie, studio: studio) }

    it 'returns a configured url for return and cancel' do
      url = Paypal.url_setup('http://www.hi.com', 'cancel', movie)
      url.should == "http://www.hi.com/api/paypal/cancel?ref=Movie&ref_id=#{movie.id}&studio_id=#{studio.id}"
    end

    it 'accepts additional parameters' do
      url = Paypal.url_setup('http://www.hi.com', 'cancel', movie, :yee => "haw")
      url.should == "http://www.hi.com/api/paypal/cancel?ref=Movie&ref_id=#{movie.id}&studio_id=#{studio.id}&yee=haw"
    end
  end

  describe ".formatted_amount" do
    it "should return an un formatted value in xx.yy format" do
      Paypal.formatted_amount(nil).should == "0.00"
      Paypal.formatted_amount(1).should == "1.00"
      Paypal.formatted_amount(1.1).should == "1.10"
      Paypal.formatted_amount(1.20).should == "1.20"
      Paypal.formatted_amount(1.255).should == "1.25"
      Paypal.formatted_amount(".1").should == "0.10"
      Paypal.formatted_amount("1").should == "1.00"
      Paypal.formatted_amount("1.1").should == "1.10"
      Paypal.formatted_amount("1.20").should == "1.20"
      Paypal.formatted_amount("1.255").should == "1.25"
    end
  end
end
