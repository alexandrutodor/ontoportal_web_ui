# frozen_string_literal: true

require 'json'

class AssistantNativeBackend
  CHUNK_SIZE = 40

  def stream(payload)
    prompt = payload[:prompt].to_s.strip
    context = payload[:context] || {}
    response_text = generate_response(prompt, context)

    # Stream in realistic word/sentence chunks
    words = response_text.split(/(\s+)/)
    buffer = +''
    words.each do |word|
      buffer << word
      if buffer.length >= CHUNK_SIZE || word.include?("\n")
        yield format_sse_chunk(buffer)
        buffer = +''
      end
    end
    yield format_sse_chunk(buffer) unless buffer.empty?
    yield "data: [DONE]\n\n"
  end

  private

  def format_sse_chunk(text)
    "data: #{JSON.generate(text: text)}\n\n"
  end

  def generate_response(prompt, context)
    prompt_lower = prompt.downcase
    page_kind = context['page_kind'].to_s
    concept_label = context['concept_label'].to_s
    concept_id = context['concept_id'].to_s
    ontology_acronym = context['ontology_acronym'].to_s
    ontology_name = context['ontology_name'].to_s
    search_query = context['search_query'].to_s

    if concept_label.present? || concept_id.present?
      generate_concept_response(prompt_lower, concept_label, concept_id, ontology_acronym, ontology_name)
    elsif ontology_acronym.present?
      generate_ontology_response(prompt_lower, ontology_acronym, ontology_name)
    elsif search_query.present?
      generate_search_response(prompt_lower, search_query)
    else
      generate_general_response(prompt_lower, page_kind)
    end
  end

  def generate_concept_response(prompt_lower, label, uri, ont_acronym, ont_name)
    display_name = label.presence || uri.split(%r{[/,#]}).last.presence || 'this concept'
    ont_display = ont_name.presence || ont_acronym.presence || 'the current ontology'

    if prompt_lower.include?('sparql') || prompt_lower.include?('query')
      <<~MARKDOWN
        ### SPARQL Query for `#{display_name}`

        Here is an executable SPARQL query to retrieve all direct triples and annotations for this concept:

        ```sparql
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX skos: <http://www.w3.org/2004/02/skos/core#>

        SELECT DISTINCT ?predicate ?object ?label WHERE {
          <#{uri}> ?predicate ?object .
          OPTIONAL { ?object rdfs:label ?label }
        }
        LIMIT 100
        ```

        To retrieve direct subclasses:
        ```sparql
        SELECT ?subClass ?label WHERE {
          ?subClass rdfs:subClassOf <#{uri}> .
          OPTIONAL { ?subClass rdfs:label ?label }
        }
        ORDER BY ?label
        ```
      MARKDOWN
    elsif prompt_lower.match?(/\b(subclass|hierarchy|parent|child|tree|super)\b/)
      <<~MARKDOWN
        ### Hierarchy & Relationships: `#{display_name}`

        - **Identifier (URI)**: `<#{uri}>`
        - **Ontology**: #{ont_display}

        In the ontology hierarchy, **#{display_name}** is modeled as a class in `#{ont_acronym}`.
        You can explore its taxonomy using the **Classes** tree tab on the left, or query its subsumption tree via the SPARQL endpoint.

        **Related Concepts to inspect:**
        - Superclasses: Check `rdfs:subClassOf` axioms
        - Associated Properties: Inspect domain/range restrictions applied to this concept.
      MARKDOWN
    else
      <<~MARKDOWN
        ### Overview: `#{display_name}`

        - **Label**: #{display_name}
        - **URI**: `<#{uri}>`
        - **Ontology**: #{ont_display} (#{ont_acronym})

        **#{display_name}** represents an ontological concept within **#{ont_display}**.
        You can inspect its metadata, annotations (such as `skos:definition`, `rdfs:comment`), mappings to other ontologies, and usage across indexed projects in this portal.

        *Tip*: Ask me to *"write a SPARQL query"* or *"show subclasses"* for this concept.
      MARKDOWN
    end
  end

  def generate_ontology_response(prompt_lower, ont_acronym, ont_name)
    ont_display = ont_name.presence || ont_acronym
    if prompt_lower.include?('sparql') || prompt_lower.include?('query')
      <<~MARKDOWN
        ### SPARQL Starter for `#{ont_acronym}`

        Run this query to sample the top classes defined in **#{ont_display}**:

        ```sparql
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        PREFIX owl: <http://www.w3.org/2002/07/owl#>

        SELECT ?class ?label (COUNT(?subClass) AS ?subClassCount) WHERE {
          ?class a owl:Class .
          OPTIONAL { ?class rdfs:label ?label }
          OPTIONAL { ?subClass rdfs:subClassOf ?class }
        }
        GROUP BY ?class ?label
        ORDER BY DESC(?subClassCount)
        LIMIT 50
        ```
      MARKDOWN
    else
      <<~MARKDOWN
        ### Ontology Assistant: `#{ont_display}` (`#{ont_acronym}`)

        You are viewing **#{ont_display}**.
        - Browse class hierarchies and properties using the tabs above.
        - Check cross-ontology mappings in the **Mappings** tab.
        - You can ask me to draft SPARQL queries, explain domain axioms, or suggest concept lookups.
      MARKDOWN
    end
  end

  def generate_search_response(prompt_lower, search_query)
    <<~MARKDOWN
      ### Search Guidance: "#{search_query}"

      You are searching for **#{search_query}**.
      - Try enclosing exact phrases in quotes (`"#{search_query}"`).
      - You can filter results by specific ontology acronyms using the facet panel.
      - If you are searching for properties rather than classes, switch to the Properties filter tab.
    MARKDOWN
  end

  def generate_general_response(prompt_lower, page_kind)
    <<~MARKDOWN
      ### OntoPortal Semantic Assistant

      I can assist you with:
      - **Ontology Exploration**: Explaining terms, definitions, and taxonomic hierarchies.
      - **SPARQL Generation**: Crafting ready-to-run queries for classes, properties, and instances.
      - **Semantic Mappings**: Finding relationships across ontologies.
      - **Catalogues**: Navigating research datasets, ML models, and scientific workflows.

      Navigate to any concept or ontology page to get contextual assistance tailored to your current view.
    MARKDOWN
  end
end
