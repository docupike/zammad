# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Reads i-doit up data through the i-doit up add-on (the only broker between
# both systems), authenticated with the add-on secret. The add-on reads i-doit up
# with its own API key.
class IdoitUp
  BRIDGE_PATH = '/api/bridge'.freeze

=begin

Verify connectivity to the add-on by fetching the class list.

  result = IdoitUp.verify(secret, addon_url)

returns

  { 'result' => [ { 'id' => '...', 'title' => 'Server' }, ... ] }

=end

  def self.verify(secret, endpoint, verify_ssl: false)
    raise __('Invalid i-doit up configuration (missing endpoint or api_token).') if secret.blank? || endpoint.blank?

    connection = { base: _normalize_endpoint(endpoint), secret: secret, verify_ssl: verify_ssl }
    { 'result' => _object_types(connection) }
  end

=begin

Query i-doit up objects or object types.

  IdoitUp.query('cmdb.object_types')
  # => { 'result' => [ { 'id' => '...', 'title' => 'Server' }, ... ] }

  IdoitUp.query('cmdb.objects', { ids: ['abc123'] })
  # => { 'result' => [ { 'id' => 'abc123', 'title' => '...', 'type_title' => '...', ... } ] }

  IdoitUp.query('cmdb.objects', { type: 'classId', title: '%search%' }, limit: 10)
  # => { 'result' => [ ... ] }

=end

  def self.query(method, filter = {}, limit: nil, offset: nil)
    setting = Setting.get('idoit_up_config')
    raise __("The required field 'api_token' is missing from the config.") if setting[:api_token].blank?
    raise __("The required field 'endpoint' is missing from the config.") if setting[:endpoint].blank?

    connection = { base: _normalize_endpoint(setting[:endpoint]), secret: setting[:api_token], verify_ssl: setting[:verify_ssl] }

    case method
    when 'cmdb.object_types'
      { 'result' => _object_types(connection) }
    when 'cmdb.objects'
      _fetch_objects(connection, filter || {}, limit: limit, offset: offset)
    else
      raise "Unsupported i-doit up method: #{method}"
    end
  end

  def self.object_link(idoit_url, object_id)
    "#{idoit_url}/object/#{CGI.escape(object_id.to_s)}"
  end

  def self._object_types(connection)
    (_rest_get(connection, '/classes')['results'] || []).map do |cls|
      {
        'id'    => cls['id'],
        'title' => cls['title'],
      }
    end
  end

  def self._fetch_objects(connection, filter, limit: nil, offset: nil)
    ids = filter[:ids] || filter['ids']

    if ids.present?
      _fetch_objects_by_ids(connection, Array(ids))
    else
      _search_objects(connection, filter, limit: limit, offset: offset)
    end
  end

  def self._fetch_objects_by_ids(connection, ids)
    class_map = _class_map(connection)
    idoit_url = _idoit_url(connection)
    items = []

    ids.each do |id|
      obj = _rest_get(connection, "/objects/#{CGI.escape(id.to_s)}")
      items << _transform_object(obj, idoit_url, class_map)
    rescue => e
      Rails.logger.warn("IdoitUp: could not fetch object #{id}: #{e.message}")
    end

    { 'result' => items }
  end

  def self._search_objects(connection, filter, limit: nil, offset: nil)
    title_query = (filter[:title] || filter['title']).to_s.delete('%').strip
    type_filter = (filter[:type] || filter['type']).to_s.strip

    params = {}
    params[:search] = title_query    if title_query.present?
    params[:limit]  = limit.to_i     if limit.present?
    params[:offset] = offset.to_i    if offset.present?

    path = '/search'
    path += "?#{params.to_query}" if params.any?

    response  = _rest_get(connection, path)
    class_map = _class_map(connection)
    idoit_url = _idoit_url(connection)

    items = (response['results'] || []).map do |obj|
      _transform_search_result(obj, idoit_url, class_map)
    end

    # Apply type filter (class ID) client-side since the search API doesn't support it.
    items = items.select { |item| item['type'] == type_filter } if type_filter.present?

    { 'result' => items }
  end

  # Transform a full object (from GET /api/v2/object/{id}) into the legacy format
  # expected by the GraphQL types and CoffeeScript sidebar.
  def self._transform_object(obj, idoit_url, class_map)
    classification = obj['classification'] || {}
    class_id = classification['id']
    {
      'id'                => obj['id'],
      'title'             => obj['title'] || '',
      'type'              => class_id,
      'type_title'        => classification['title'] || class_map[class_id] || '',
      'cmdb_status'       => obj['status'].to_s,
      'cmdb_status_title' => _status_label(obj['status']),
      'link'              => object_link(idoit_url, obj['id']),
    }
  end

  # Transform a search result (from GET /api/v2/search) into the legacy format.
  def self._transform_search_result(obj, idoit_url, class_map)
    class_id = obj['class']
    {
      'id'                => obj['id'],
      'title'             => obj['title'] || '',
      'type'              => class_id,
      'type_title'        => class_map[class_id] || class_id || '',
      'cmdb_status'       => '2',
      'cmdb_status_title' => 'normal',
      'link'              => object_link(idoit_url, obj['id']),
    }
  end

  # Cached class-ID → title map (refreshed every 5 minutes). Class titles are
  # not user-specific, so one cache per add-on endpoint is sufficient.
  def self._class_map(connection)
    _cached(:class_map, connection[:base]) do
      (_rest_get(connection, '/classes')['results'] || []).to_h { |cls| [cls['id'], cls['title']] }
    end
  end

  # Public i-doit up base URL as known by the add-on (cached 5 minutes).
  def self._idoit_url(connection)
    _cached(:idoit_url, connection[:base]) do
      url = _rest_get(connection, '/config')['idoitUrl'].to_s
      raise "Invalid i-doit up URL '#{url}' reported by the add-on" if !url.match?(%r{\Ahttps?://}i)

      url.chomp('/')
    end
  end

  def self._cached(name, key)
    @_cache ||= {}
    entry = @_cache[[name, key]]
    return entry[:data] if entry && entry[:expires_at] > Time.current

    data = yield
    @_cache[[name, key]] = { data: data, expires_at: 5.minutes.from_now }
    data
  end

  # i-doit up status codes: 2 = normal, 3 = archived, 4 = deleted
  def self._status_label(status)
    case status.to_i
    when 2 then 'normal'
    when 3 then 'archived'
    when 4 then 'deleted'
    else        'unknown'
    end
  end

  def self._rest_get(connection, path)
    url = "#{connection[:base]}#{BRIDGE_PATH}#{path}"
    result = UserAgent.get(
      url,
      {},
      {
        headers:      { 'Authorization' => "Bearer #{connection[:secret]}" },
        verify_ssl:   connection[:verify_ssl],
        json:         true,
        open_timeout: 6,
        read_timeout: 16,
        log:          { facility: 'idoit_up' },
      },
    )

    raise "Can't fetch from #{url}: Unable to parse response." if !result.success? && result.error.to_s.include?('JSON::ParserError')
    raise "Can't fetch from #{url}: #{result.error}" if !result.success?

    result.data || {}
  end

  def self._normalize_endpoint(url)
    url = url.to_s.strip
    raise "Invalid endpoint '#{url}', need to start with http:// or https://" if !url.match?(%r{^https?://}i)

    url.chomp('/')
  end
end
