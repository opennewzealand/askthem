# Billy
class Person
  include Mongoid::Document

  # authorization based on roles
  # i.e. a user.can_respond_as?(person) to answer questions
  resourcify :user_roles, role_cname: 'UserRole'

  # The person's jurisdiction.
  belongs_to :metadatum, foreign_key: 'state'
  # Questions addressed to the person.
  has_many :questions

  # a user identified as the person
  # potentially elected official's staff would also have a user account
  # identified as the same person, thus has_many
  has_many :identities

  # Popolo fields and aliases.
  field :full_name, type: String, as: :name
  field :leg_id, type: String, as: :slug
  field :last_name, type: String, as: :family_name
  field :first_name, type: String, as: :given_name
  field :middle_name, type: String, as: :additional_name
  field '+title', type: String, as: :honorific_prefix # always "" in OpenStates
  field :suffixes, type: String, as: :honorific_suffix
  field :email, type: String
  field '+gender', type: String, as: :gender
  field :photo_url, type: String, as: :image
  # @todo move chamber to legislator mixin
  # and refactor dependencies on chamber being present
  field :chamber, type: String

  # social media handling
  field :twitter_id, type: String
  # mainly to be used for quick look up, save as downcase
  field :additional_twitter_ids, type: Array

  # whether to show them on homepage or not
  # assumes only one person flagged featured
  field :featured, type: Boolean, default: false

  index(_type: 1)
  index(state: 1)
  index(active: 1)
  index(featured: 1)
  index(twitter_id: 1)
  index(additional_twitter_ids: 1)
  index(chamber: 1) # only applicable to legislators

  scope :active, where(active: true).asc(:chamber, :family_name) # no index includes `last_name`
  scope :featured, where(featured: true)

  delegate :signature_threshold, :biography, :links, to: :person_detail

  # only one featured person at a time
  after_save :make_all_others_unfeatured, if: :featured?

  # expensive, do this only when constrained by connected_to or the like
  def self.some_name_matches(name_fragment)
    any_of({ full_name: name_fragment },
           { first_name: name_fragment },
           { last_name: name_fragment },
           { full_name: /#{name_fragment}/i },
           { first_name: /#{name_fragment}/i },
           { last_name: /#{name_fragment}/i })
  end

  def self.only_types(types)
    where("_type" => { "$in" => types })
  end

  # non-chainable
  def self.criteria_for_types_for_location(location)
    location = LocationFormatter.new(location).format
    return where(id: nil) if location.nil?

    criteria = distinct("_type").collect do |type|
      type = "Person" if type.blank?
      type.constantize.for_location(location)
    end
  end

  def self.for_location(location, api = nil)
    if self.name != "Person"
      raise "this class needs a real implementation of for_location"
    end

    # plain Person cannot be relied on to have location data
    where('false')
  end

  # non-chainable
  def self.results_for_location(location)
    if self.name != "Person"
      raise "should not be called from subclass"
    end

    criteria_for_types_for_location(location).inject([]) do |results, criterium|
      results += criterium
    end
  end

  def self.default_api
    OpenStatesLegislatorService
  end

  # for now, only run if we have a clean slate
  def self.load_from_apis_for_jurisdiction(abbreviation, api = nil, adapter = nil)
    return if self.connected_to(abbreviation).count > 0

    api ||= default_api.new
    api.parsed_results_for_jurisdiction(abbreviation).map do |attributes|
      new.load_from_apis!(attributes, adapter: adapter)
    end
  end

  # @todo needs spec
  def load_from_apis!(attributes, options = {})
    adapt(attributes, options).save!
    PersonDetailRetriever.new(self, options).retrieve!
    self
  end

  # Inactive legislators will not have top-level `chamber` or `district` fields.
  #
  # @param [String,Symbol] `:chamber` or `:district`
  # @return [String,nil] the chamber, the district, or nil
  def most_recent(attribute)
    if read_attribute(attribute)
      read_attribute(attribute)
    else
      read_attribute(:old_roles).to_a.reverse.each do |_, roles|
        if roles
          roles.each do |role|
            return role[attribute.to_s] if role[attribute.to_s]
          end
        end
      end
      nil # don't return the enumerator
    end
  end

  # What political role does the person currently play?
  # Can be elected or something other like "adviser" or "spokesperson", etc.
  #
  # Expected to be fully meaningful in combination with class and perhaps
  # metadatum (e.g name of chamber for StateLegislator like "upper").
  #
  # Subclasses may populate with a dedicated field or dynamically based on
  # another value.
  #
  # Meant for programmatic use, all lower case.
  #
  # @return [String, nil]
  def political_position
    read_attribute(:political_position)
  end

  # Meant as common formal presentation of political position.
  #
  # Yeah, I know, it's presentation concern, but may be dynamically generated
  # in subclasses based on relation with metadatum and its own class.
  #
  # @return [String, nil]
  def political_position_title
    political_position ? political_position.humanize : nil
  end

  # Returns fields that are not available in Billy.
  #
  # @return [PersonDetail] the person's additional fields
  # @note `has_one` associations require a matching `belongs_to`, as they must
  #   be able to call `inverse_of_field`.
  def person_detail
    PersonDetail.where(person_id: id).first || PersonDetail.new(person: self)
  end

  # Returns the person's special interest group ratings.
  def ratings
    Rating.where(candidateId: votesmart_id || person_detail.votesmart_id)
  end

  # Returns questions answered by the person.
  def questions_answered
    questions.where(answered: true)
  end

  # Returns the person's sponsored bills.
  def bills
    Bill.where('sponsors.leg_id' => id)
  end

  # Returns the person's votes.
  def votes
    Vote.or({'yes_votes.leg_id' => id},
            {'no_votes.leg_id' => id},
            {'other_votes.leg_id' => id}) # no index
  end

  # Returns the person's committees.
  def committees
    roles = read_attribute(:roles)
    return Committee.where(id: []) unless roles

    ids = roles.map { |x| x['committee_id'] }.compact
    return Committee.in(id: []) unless ids.any?

    Committee.in(id: ids)
  end

  def verified?
    identities.where(status: 'verified').count > 0
  end

  def votesmart_id
    read_attribute(:votesmart_id)
  end

  def votesmart_biography_url
    votesmart_url('biography')
  end

  def votesmart_evaluations_url
    votesmart_url('evaluations')
  end

  def votesmart_key_votes_url
    votesmart_url('key-votes')
  end

  def votesmart_public_statements_url
    votesmart_url('public-statements')
  end

  def votesmart_campaign_finance_url
    votesmart_url('campaign-finance')
  end

  # so subclasses use standard _person partial
  # unless otherwise specified
  def to_partial_path
    "people/person"
  end

  private
  def votesmart_url(section = nil)
    if votesmart_id
      url = "http://votesmart.org/candidate/"
      url += "#{section}/" if section
      url += votesmart_id
    end
  end

  def adapt(attributes, options = {})
    adapter = options[:adapter]
    if adapter
      adapter.run(attributes)
    else
      self.attributes = attributes
    end

    # id cannot be mass assigned..., have to set it explictly
    # id = attributes['id']
    self
  end

  def make_all_others_unfeatured
    # specify superclass to get all people in subclasses
    Person.featured.nin(id: [id]).each do |record|
      record.update_attributes(featured: false)
    end
  end
end
