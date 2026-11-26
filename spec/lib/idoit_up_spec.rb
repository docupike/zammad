# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe IdoitUp do
  let(:secret)    { 'shared-secret' }
  let(:endpoint)  { 'https://addon.example.com' }
  let(:idoit_url) { 'https://idoit-up.example.com' }

  before do
    described_class.instance_variable_set(:@_cache, nil)
    allow(Setting).to receive(:get).and_call_original
    allow(Setting).to receive(:get).with('idoit_up_config').and_return(
      { api_token: secret, endpoint: endpoint, verify_ssl: false }
    )
  end

  def stub_bridge(responses)
    allow(described_class).to receive(:_rest_get) do |_connection, path|
      responses.fetch(path) { raise "unexpected bridge call #{path}" }
    end
  end

  describe '.verify' do
    it 'raises on missing configuration', :aggregate_failures do
      expect { described_class.verify('', endpoint) }
        .to raise_error(RuntimeError, %r{missing endpoint or api_token})
      expect { described_class.verify(secret, '') }
        .to raise_error(RuntimeError, %r{missing endpoint or api_token})
    end

    it 'returns the class list from the add-on' do
      stub_bridge('/classes' => { 'results' => [{ 'id' => 'C__OBJTYPE__SERVER', 'title' => 'Server' }] })

      expect(described_class.verify(secret, endpoint)['result'])
        .to eq([{ 'id' => 'C__OBJTYPE__SERVER', 'title' => 'Server' }])
    end
  end

  describe '.query' do
    it 'returns object types' do
      stub_bridge('/classes' => { 'results' => [{ 'id' => 'C__OBJTYPE__SERVER', 'title' => 'Server' }] })

      expect(described_class.query('cmdb.object_types')['result'].first['title']).to eq('Server')
    end

    it 'returns objects by id with links into i-doit up' do
      stub_bridge(
        '/classes'         => { 'results' => [{ 'id' => 'C__OBJTYPE__SERVER', 'title' => 'Server' }] },
        '/config'          => { 'idoitUrl' => "#{idoit_url}/" },
        '/objects/abc-123' => {
          'id'             => 'abc-123',
          'title'          => 'webserver01',
          'status'         => 2,
          'classification' => { 'id' => 'C__OBJTYPE__SERVER', 'title' => 'Server' },
        },
      )

      expect(described_class.query('cmdb.objects', { ids: ['abc-123'] })['result'].first).to include(
        'id'    => 'abc-123',
        'title' => 'webserver01',
        'link'  => "#{idoit_url}/object/abc-123",
      )
    end

    it 'searches and filters by class' do
      stub_bridge(
        '/classes'           => { 'results' => [] },
        '/config'            => { 'idoitUrl' => idoit_url },
        '/search?search=web' => { 'results' => [
          { 'id' => '1', 'title' => 'web1', 'class' => 'A' },
          { 'id' => '2', 'title' => 'web2', 'class' => 'B' },
        ] },
      )

      result = described_class.query('cmdb.objects', { title: '%web%', type: 'B' })['result']
      expect(result.pluck('id')).to eq(['2'])
    end

    it 'raises on an unsupported method' do
      expect { described_class.query('unsupported.method') }
        .to raise_error(RuntimeError, %r{Unsupported i-doit up method})
    end
  end

  describe '._rest_get' do
    let(:connection) { { base: endpoint, secret: secret, verify_ssl: false } }

    it 'calls the add-on bridge with the add-on secret', :aggregate_failures do
      allow(UserAgent).to receive(:get).and_return(instance_double(UserAgent::Result, success?: true, data: { 'ok' => true }))

      expect(described_class._rest_get(connection, '/classes')).to eq({ 'ok' => true })
      expect(UserAgent).to have_received(:get)
        .with("#{endpoint}/api/bridge/classes", {}, hash_including(headers: { 'Authorization' => "Bearer #{secret}" }))
    end
  end

  describe '._normalize_endpoint' do
    it 'strips trailing slash' do
      expect(described_class._normalize_endpoint('https://example.com/')).to eq('https://example.com')
    end

    it 'raises on non-http URL' do
      expect { described_class._normalize_endpoint('ftp://example.com') }
        .to raise_error(RuntimeError, %r{Invalid endpoint})
    end
  end

  describe '._status_label' do
    it { expect(described_class._status_label(2)).to eq('normal') }
    it { expect(described_class._status_label(3)).to eq('archived') }
    it { expect(described_class._status_label(4)).to eq('deleted') }
    it { expect(described_class._status_label(99)).to eq('unknown') }
  end
end
