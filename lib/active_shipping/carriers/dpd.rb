module ActiveShipping
  class DPD < Carrier
    self.retry_safe = true

    cattr_reader :name
    @@name = "DPD"

    attr_reader :geo_session

    API_URL = 'https://api.dpd.co.uk'

    def initialize(options = {})
      super options

      login
    end

    def create_shipment(origin, destination, packages, line_items = [], options = {})
      options = @options.update(options)
      packages = Array(packages)
      raise Error, "Multiple packages are not supported yet." if packages.length > 1

      request = build_shipment_request(origin, destination, packages, line_items, options)
      logger.debug(request) if logger

      response = perform "/shipping/shipment", {}, request

      begin
        tracking_number = response[:data][:consignmentDetail].first[:parcelNumbers].first
        shipment_id = response[:data][:shipmentId]
      rescue
        raise ResponseError, response.inspect
      end

      labels = [Label.new(tracking_number, get_label(shipment_id))]
      LabelResponse.new(true, "", response, {labels: labels})
    end

    protected

    def login
      auth = Base64.encode64 "#{@options[:username]}:#{@options[:password]}"
      headers = { "Authorization" => "Basic #{auth}" }

      response = perform "/user", { action: :login }, nil, headers
      @geo_session = response[:data][:geoSession]
    end

    def get_label(shipment_id)
      url = "#{API_URL}/shipping/shipment/#{shipment_id}/label"

      headers = { "Accept" => "text/html" }
      headers = add_geo_headers(headers)

      ssl_get(url, headers)
    end

    def build_shipment_request(origin, destination, packages, line_items = [], options = {})
      Jbuilder.new do |json|
        json.collectionOnDelivery false
        json.invoice nil
        json.collectionDate DateTime.current + 1.hour
        json.consolidate false

        json.consignment packages do |package|
          json.consignmentNumber nil
          json.consignmentRef nil
          json.parcels []

          json.collectionDetails do
            build_contact_details json, origin
          end

          json.deliveryDetails do
            build_contact_details json, destination

            json.notificationDetails do
              json.email packages.first.options[:email]
              json.mobile destination.phone
            end
          end

          json.networkCode options[:network_code]
          json.numberOfParcels 1
          json.totalWeight [package.kgs, 1].max
          json.shippingRef1 package.options[:reference_numbers].first[:value]
          json.customsValue nil
          json.parcelDescription nil
        end
      end.target!
    end

    def build_contact_details(json, location)
      json.contactDetails do
        json.contactName location.name
        json.telephone location.phone
      end

      json.address do
        json.organisation location.company_name
        json.countryCode location.country.code(:alpha2).value
        json.postcode location.postal_code
        json.street location.address1
        json.locality location.address2
        json.town location.city
        json.county location.province
      end
    end

    def service_list_params(origin, destination)
      {
        "collectionDetails.address.county" => origin.province,
        "collectionDetails.address.postcode" => origin.postal_code,
        "collectionDetails.address.countryCode" => origin.country.code(:alpha2).value,
        "deliveryDetails.address.county" => destination.province,
        "deliveryDetails.address.postcode" => destination.postal_code,
        "deliveryDetails.address.countryCode" => destination.country.code(:alpha2).value,
        "deliveryDirection" => 1,
        "numberOfParcels" => 1,
        "totalWeight" => 1,
        "shipmentType" => 0
      }
    end

    def add_geo_headers(headers)
      headers["GEOClient"] = "account/#{@options[:account_id]}"
      headers["GEOSession"] = geo_session if geo_session.present?
      headers
    end

    def perform(path, query = {}, data = nil, headers = {})
      query[:test] = true if test_mode?

      url = "#{API_URL}#{path}?#{query.to_query}"

      headers = add_geo_headers(headers)

      headers["Content-Type"] = "application/json"
      headers["Accept"] = "application/json"

      JSON.parse(ssl_post(url, data, headers)).with_indifferent_access
    end
  end
end
