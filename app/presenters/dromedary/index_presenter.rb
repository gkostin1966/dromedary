# frozen_string_literal: true

require 'json'
require 'delegate'
require 'middle_english_dictionary'

module Dromedary

  class IndexPresenter < SimpleDelegator

    # @return [MiddleEnglishDictionary::Entry] The underlying entry object
    attr_reader :entry

    # Create a new object in the same style as a Blacklight::IndexPresenter
    # This is not a subclass, but it delegates unknown methods to a
    # Blacklight::IndexPresenter underneath
    #
    # The main thing we do is provide the underlying MiddleEnglishDictionary::Entry
    # object.
    def initialize(document, view_context, configuration = view_context.blacklight_config)
      blacklight_index_presenter = Blacklight::IndexPresenter.new(document, view_context, configuration)
      __setobj__(blacklight_index_presenter)
      # we know we get @document for sure. Hydrate an Entry from the json
      @entry    = MiddleEnglishDictionary::Entry.from_json(document.fetch('json'))
      @document = document

      # Get the nokonode for later XSL processing
      @nokonode = Nokogiri::XML(@document.fetch('xml'))

      # We can dig in and find out what type of search was done
      @search_field = view_context.search_state.params_for_search['search_field']
    end


    ##### XSLT TRANSFORMS #####

    # Let's load up the XSLT transforms as constants
    # so we only get them once
    XSL_DIR = Pathname.new "./indexer/xslt"


    def self.load_xslt(basename)
      Nokogiri::XSLT(File.open(XSL_DIR + basename, 'r:utf-8').read)
    end


    FORM_XSLT       = load_xslt('FormOnly.xsl')
    DEF_XSLT        = load_xslt('DefOnly.xsl')
    CIT_XSLT        = load_xslt('CitOnly.xsl')
    ETYM_XSLT       = load_xslt('EtymOnly.xsl')
    NOTE_XSLT       = load_xslt('NoteOnly.xsl')
    SUPPLEMENT_XSLT = load_xslt('SupplementOnly.xsl')


    # There's only one FORM section, so just take care of it here
    # @return [String] the transformed form, or nil
    def form_html
      xsl_transform_from_entry('/ENTRYFREE/FORM', FORM_XSLT)
    end


    # There's only one ETYM section, so just take care of it here
    # @return [String] the transformed etym, or nil
    def etym_html
      xsl_transform_from_entry('/ENTRYFREE/ETYM', ETYM_XSLT)
    end


    # @param [MiddleEnglishDictionary::Entry::Sense] sense The sense whose def you want
    # @return [String, nil] The definition transformed into HTML, or nil
    def def_html(sense)
      xsl_transform_from_xml(sense.definition_xml, DEF_XSLT)
    end


    # @param [MiddleEnglishDictionary::Entry::Note] note The note object
    # @return [String, nil] The note transformed into HTML, or nil
    def note_html(note)
      xsl_transform_from_xml(note.xml, NOTE_XSLT)
    end

    # @param [MiddleEnglishDictionary::Entry::Citation] cit The citation object
    # @return [String, nil] The citatation transformed into HTML, or nil
    def cit_html(cit)
      xsl_transform_from_xml(cit.xml, CIT_XSLT)
    end

    alias_method :cite_html, :cit_html
    alias_method :citation_html, :cit_html

    # @param [MiddleEnglishDictionary::Entry::Supplement] supplement The supplement object
    # @return [String, nil] The supplement transformed into HTML, or nil
    def supplement_html(supplement)
      xsl_transform_from_xml(supplement.xml, SUPPLEMENT_XSLT)
    end


    ####### Ealier Methods #####

    # @return [String] The cleaned-up POS abbreviation (e.g., "n" or "v")
    def part_of_speech_abbrev
      @entry.pos
    end


    # @return [Array<MiddleEnglishDictionary::Sense>] All the entry senses
    # modified to replace '~' with regularized headword
    def senses
      headw = @entry.headwords.first.instance_variable_get(:@regs).first
      @entry.senses.each {|sen| sen.definition_xml.gsub! '~', headw}
      @entry.senses
    end


    # @return [Integer] The number of quotes across all senses
    def quote_count
      @entry.all_quotes.count
    end


    # @return [Array<String>] The headwords as taken from the "highlight"
    # section of the solr return (with embedded tags for highlighting)
    def highlighted_official_headword
      Array(hl_field('official_headword')).first
    end


    # @return [Array<String>] The non-headword spellings as taken from the "highlight"
    # section of the solr return (with embedded tags for highlighting)
    def highlighted_other_spellings
      hl_field('headword').reject {|w| w == highlighted_official_headword}
    end


    # A convenience method to get the highlighted values for a field if
    # they're available, falling back to the regular document values for
    # that field if they're not in the highlighted values section of the
    # Solr response
    #
    # @param [String] Name of the solr field
    # @return [Array<String>] The highlighted versions of the field given,
    # or the non-highlighted values if there aren't any highlights.
    def hl_field(k)
      if @document.has_highlight_field?(k)
        @document.highlight_field(k)
      elsif @document.has_field?(k)
        Array(@document.fetch(k))
      else
        []
      end
    end


    ####### XSLT Transform helpers #####

    # Create a document from the given node, or nil if nil was passed
    # @param [Nokogiri::XML::Node] node The node to document-ify
    # @return [Nokgiri::XML::Document] A document containing nothing but that node
    def doc_from_node(node)
      return nil if node.nil?
      return node.dup if node.document?
      doc = Nokogiri::XML::Document.new
      doc.add_child node.dup
      doc
    end


    # We need to pass a full XML document node (not just an element) to
    # the XSLT transform, so we make one here.
    #
    # Given an xpath, find the first corresponding node in the @entry
    # nokonode and turn it into a free-standing document that contains
    # only that node
    # @param [String] xpath The xpath in the @entry nokonode (starting with '/ENTRY')
    # @return [Nokogiri::XML::Document, nil] The created nokogiri document, or nil if not found
    def doc_from_xpath(xpath)
      doc_from_node(@nokonode.xpath(xpath).first)
    end


    # Given a nokogiri node, turn it into a document (if it isn't already)
    # and apply the provided xslt transformation
    # @param [String] xpath The xpath into the entry (root is '/ENTRYFREE')
    # @param [Nokogiri::XSLT] xslt The XSLT object used to do the transformation
    # @return [String,nil] The transfored text (usualy html), or nil if the xpath not found
    def xsl_transform_from_node(node, xslt)
      return nil if node.nil?
      xslt.apply_to(doc_from_node(node))
    end


    # Given an XML snippet or nil, and an xslt object, return
    # the transformation (or nil if the snippet was nil)
    # @param [String,nil] xml The raw XML string, or nil
    # @param [Nokogiri::XSLT] xslt The XSLT object used to do the transformation
    # @return [String,nil] The transfored text (usualy html), or nil if the xpath not found
    def xsl_transform_from_xml(xml, xslt)
      return nil if xml.nil?
      xsl_transform_from_node(Nokogiri::XML(xml), xslt)
    end

    # Given an xpath in the @entry nokonode (sent to #doc_from_xpath) and
    # an xslt transform (probably from the constants above), return the
    # transformed-into-html value
    #
    # @param [String] xpath The xpath into the entry (root is '/ENTRYFREE')
    # @param [Nokogiri::XSLT] xslt The XSLT object used to do the transformation
    # @return [String,nil] The transfored text (usualy html), or nil if the xpath not found
    def xsl_transform_from_entry(xpath, xslt)
      xsl_transform_from_node(doc_from_xpath(xpath), xslt)
    end

  end
end

