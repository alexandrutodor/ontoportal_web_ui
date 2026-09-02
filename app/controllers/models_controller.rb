class ModelsController < ApplicationController
  layout :determine_layout
  before_action :require_models_catalogue if respond_to?(:before_action)

  SECTIONS = %w[overview model_card datasets papers code inference].freeze

  DEFAULT_MODEL_CARD = {
    parameters: 'Unknown',
    size: 'Unknown',
    architecture: 'Unknown',
    framework: 'Unknown',
    precision: 'Unknown',
    inputs: 'Unknown',
    outputs: 'Unknown',
    version: 'Unknown',
    size_caveat: 'Published checkpoint and download sizes vary depending on model precision, compression, weights format, and checkpoint variant.'
  }.freeze

  SORT_OPTIONS = [
    ['Name ascending', 'name_asc'],
    ['Name descending', 'name_desc'],
    ['FAIR readiness', 'fair_desc']
  ].freeze

  FAIR_PROFILE = 'ontoportal-model-fair-metadata-readiness-v1'.freeze
  FAIR_DISCLAIMER = 'Model FAIR metadata readiness v1 is an automated heuristic reflecting public catalogue metadata completeness across Findability, Accessibility, Interoperability, and Reusability. It is a metadata-readiness indicator, not a formal certification, and is not directly comparable to ontology (O\'FAIRe) or dataset FAIR evaluations.'.freeze
  FAIR_METHODOLOGY = 'Methodology: 16 objective catalogue checks grouped across 4 principles (4 checks per principle, 25% each). Principle scores range from 0% to 100%. The overall score is the unweighted mean of F, A, I, and R principle scores, rounded to the nearest integer.'.freeze

  helper_method :model_card_for, :fair_score_for if respond_to?(:helper_method)

  CATALOGUE = [
    {
      id: 'mattergen',
      slices: [],
      name: 'MatterGen',
      organization: 'Microsoft Research',
      summary: 'A generative model for inorganic materials design.',
      tasks: ['materials generation', 'crystal structure generation'],
      domains: ['inorganic materials', 'crystal structures'],
      tags: ['generative model', 'diffusion', 'materials design'],
      hubs: ['Hugging Face'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials Project', relationship: 'training data', search: 'Materials Project' }],
        papers: [{ label: 'MatterGen paper', relationship: 'publication', url: 'https://arxiv.org/abs/2312.03687' }],
        code: [{ label: 'MatterGen model card', relationship: 'model card', url: 'https://huggingface.co/microsoft/mattergen' }],
        inference: []
      }
    },
    {
      id: 'omat24',
      slices: [],
      name: 'OMat24',
      organization: 'Meta FAIR',
      summary: 'An open atomistic materials dataset and model family for materials modeling.',
      tasks: ['property prediction', 'energy and force prediction'],
      domains: ['inorganic materials', 'atomistic simulation'],
      tags: ['foundation model', 'open dataset', 'DFT'],
      hubs: ['Hugging Face'],
      license: 'Custom/terms',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'OMat24', relationship: 'primary dataset', search: 'OMat24' }],
        papers: [{ label: 'OMat24 preprint', relationship: 'publication', url: 'https://arxiv.org/abs/2410.12771' }],
        code: [{ label: 'OMat24 model card', relationship: 'model card', url: 'https://huggingface.co/facebook/OMAT24' }],
        inference: []
      }
    },
    {
      id: 'mace-mh-1',
      slices: [],
      name: 'MACE-MH-1',
      organization: 'MACE Foundation',
      summary: 'A MACE foundation model for atomistic materials and molecular modeling.',
      tasks: ['energy and force prediction', 'molecular dynamics'],
      domains: ['materials', 'molecules', 'atomistic simulation'],
      tags: ['foundation model', 'equivariant model', 'interatomic potential'],
      hubs: ['Hugging Face'],
      license: 'ASL (Academic Software License)',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials Project', relationship: 'materials reference data', search: 'Materials Project' }],
        papers: [{ label: 'MACE paper', relationship: 'publication', url: 'https://arxiv.org/abs/2206.07202' }],
        code: [{ label: 'MACE-MH-1 model card', relationship: 'model card', url: 'https://huggingface.co/mace-foundations/mace-mh-1' }],
        inference: []
      }
    },
    {
      id: 'mattersim',
      slices: [],
      name: 'MatterSim',
      organization: 'Microsoft Research',
      summary: 'A deep-learning atomistic model for materials simulation across temperatures and pressures.',
      tasks: ['energy and force prediction', 'molecular dynamics'],
      domains: ['materials', 'atomistic simulation'],
      tags: ['foundation model', 'interatomic potential', 'molecular dynamics'],
      hubs: ['GitHub'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'MatterSim data', relationship: 'training data', search: 'MatterSim' }],
        papers: [{ label: 'MatterSim preprint', relationship: 'publication', url: 'https://arxiv.org/abs/2405.04967' }],
        code: [{ label: 'MatterSim repository', relationship: 'source code', url: 'https://github.com/microsoft/mattersim' }],
        inference: []
      }
    },
    {
      id: 'chgnet',
      slices: [],
      name: 'CHGNet',
      organization: 'Ceder Group',
      summary: 'A charge-informed graph neural network potential for crystals and atomistic simulation.',
      tasks: ['energy and force prediction', 'molecular dynamics', 'structure relaxation'],
      domains: ['crystals', 'inorganic materials', 'atomistic simulation'],
      tags: ['graph neural network', 'interatomic potential', 'charge-informed'],
      hubs: ['GitHub'],
      license: 'BSD-3-Clause',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials Project', relationship: 'training data', search: 'Materials Project' }],
        papers: [{ label: 'CHGNet paper', relationship: 'publication', url: 'https://arxiv.org/abs/2302.14231' }],
        code: [{ label: 'CHGNet repository', relationship: 'source code', url: 'https://github.com/CederGroupHub/chgnet' }],
        inference: []
      }
    },
    {
      id: 'matgl-m3gnet',
      slices: [],
      name: 'MatGL / M3GNet',
      organization: 'Materials Virtual Lab',
      summary: 'A materials graph library and universal interatomic-potential family.',
      tasks: ['property prediction', 'energy and force prediction', 'molecular dynamics'],
      domains: ['inorganic materials', 'crystals', 'atomistic simulation'],
      tags: ['graph neural network', 'interatomic potential', 'materials library'],
      hubs: ['GitHub'],
      license: 'BSD-3-Clause',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials Project', relationship: 'materials reference data', search: 'Materials Project' }],
        papers: [{ label: 'M3GNet paper', relationship: 'publication', url: 'https://doi.org/10.1038/s43588-022-00349-3' }],
        code: [{ label: 'MatGL repository', relationship: 'source code', url: 'https://github.com/materialyzeai/matgl' }],
        inference: []
      }
    },
    {
      id: 'sevennet',
      slices: [],
      name: 'SevenNet',
      organization: 'MDIL, Seoul National University',
      summary: 'An equivariant neural-network potential for large-scale atomistic simulation.',
      tasks: ['energy and force prediction', 'molecular dynamics'],
      domains: ['materials', 'molecules', 'atomistic simulation'],
      tags: ['equivariant model', 'interatomic potential', 'molecular dynamics'],
      hubs: ['GitHub'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials Project', relationship: 'materials reference data', search: 'Materials Project' }],
        papers: [{ label: 'SevenNet preprint', relationship: 'publication', url: 'https://arxiv.org/abs/2402.03789' }],
        code: [{ label: 'SevenNet repository', relationship: 'source code', url: 'https://github.com/MDIL-SNU/SevenNet' }],
        inference: []
      }
    },
    {
      id: 'orb',
      slices: [],
      name: 'Orb',
      organization: 'Orbital Materials',
      summary: 'A family of machine-learning force fields for atomistic materials simulation.',
      tasks: ['energy and force prediction', 'molecular dynamics', 'structure relaxation'],
      domains: ['materials', 'molecules', 'atomistic simulation'],
      tags: ['foundation model', 'interatomic potential', 'force field'],
      hubs: ['GitHub'],
      license: 'Apache-2.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Orb training data', relationship: 'training data', search: 'Orb materials model' }],
        papers: [{ label: 'Orb preprint', relationship: 'publication', url: 'https://arxiv.org/abs/2410.22570' }],
        code: [{ label: 'Orb models repository', relationship: 'source code', url: 'https://github.com/orbital-materials/orb-models' }],
        inference: []
      }
    },
    {
      id: 'alignn',
      slices: [],
      name: 'ALIGNN',
      organization: 'National Institute of Standards and Technology',
      summary: 'A graph neural network using atomistic line graphs for materials-property prediction.',
      tasks: ['property prediction', 'formation energy prediction'],
      domains: ['materials', 'crystals', 'inorganic materials'],
      tags: ['graph neural network', 'line graph', 'property prediction'],
      hubs: ['GitHub'],
      license: 'See repository terms',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'JARVIS', relationship: 'training and evaluation data', search: 'JARVIS materials database' }],
        papers: [{ label: 'ALIGNN paper', relationship: 'publication', url: 'https://doi.org/10.1038/s41524-021-00650-1' }],
        code: [{ label: 'ALIGNN repository', relationship: 'source code', url: 'https://github.com/usnistgov/alignn' }],
        inference: []
      }
    },
    {
      id: 'pet-mad',
      slices: [],
      name: 'PET-MAD',
      organization: 'COSMO',
      summary: 'A pretrained equivariant transformer for molecular and atomic dynamics.',
      tasks: ['energy and force prediction', 'molecular dynamics'],
      domains: ['materials', 'molecules', 'atomistic simulation'],
      tags: ['pretrained model', 'equivariant model', 'atomistic dynamics'],
      hubs: ['Hugging Face'],
      license: 'BSD-3-Clause',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'MAD dataset', relationship: 'training data', search: 'MAD materials dataset' }],
        papers: [{ label: 'PET-MAD paper', relationship: 'publication', url: 'https://doi.org/10.1038/s41467-025-65662-7' }],
        code: [{ label: 'PET-MAD model card', relationship: 'model card', url: 'https://huggingface.co/lab-cosmo/pet-mad' }],
        inference: []
      }
    },
    {
      id: 'matscibert',
      slices: [],
      name: 'MatSciBERT',
      organization: 'IIT Delhi',
      summary: 'A scientific language model pretrained on materials-science literature.',
      tasks: ['text representation', 'named-entity recognition', 'text classification'],
      domains: ['materials science', 'scientific text'],
      tags: ['language model', 'NLP', 'literature mining'],
      hubs: ['Hugging Face'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials text corpus', relationship: 'training corpus', search: 'Materials science NLP corpus' }],
        papers: [{ label: 'MatSciBERT paper', relationship: 'publication', url: 'https://doi.org/10.1038/s41524-022-00784-w' }],
        code: [{ label: 'MatSciBERT model card', relationship: 'model card', url: 'https://huggingface.co/m3rg-iitd/matscibert' }],
        inference: [
          { label: 'Hugging Face Inference API (authentication required)', relationship: 'hosted inference endpoint', url: 'https://router.huggingface.co/hf-inference/models/m3rg-iitd/matscibert' },
          { label: 'Hugging Face Inference Providers', relationship: 'provider documentation', url: 'https://huggingface.co/docs/inference-providers' }
        ]
      }
    },
    {
      id: 'smi-ted',
      slices: ["chemistry"],
      name: 'SMI-TED',
      organization: 'IBM Research',
      summary: 'A SMILES-based transformer encoder-decoder foundation model for molecular property prediction and representations.',
      tasks: ['property prediction', 'representation learning'],
      domains: ['molecules', 'materials', 'chemistry'],
      tags: ['foundation model', 'encoder-decoder', 'SMILES', 'property prediction'],
      hubs: ['Hugging Face'],
      license: 'Apache-2.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'PubChem molecules', relationship: 'training data', search: 'PubChem' }],
        papers: [{ label: 'SMI-TED preprint', relationship: 'publication', url: 'https://arxiv.org/abs/2407.13524' }],
        code: [{ label: 'SMI-TED model card', relationship: 'model card', url: 'https://huggingface.co/ibm-research/materials.smi-ted' }],
        inference: []
      }
    },
    {
      id: 'selfies-ted',
      slices: ["chemistry"],
      name: 'SELFIES-TED',
      organization: 'IBM Research',
      summary: 'A transformer model for molecular representations expressed with SELFIES.',
      tasks: ['molecular generation', 'text representation'],
      domains: ['molecules', 'chemical language'],
      tags: ['language model', 'SELFIES', 'molecular modeling'],
      hubs: ['Hugging Face'],
      license: 'Apache-2.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'PubChem SELFIES', relationship: 'training data', search: 'PubChem' }],
        papers: [{ label: 'SELFIES-TED preprint', relationship: 'publication', url: 'https://arxiv.org/abs/2407.13524' }],
        code: [{ label: 'SELFIES-TED model card', relationship: 'model card', url: 'https://huggingface.co/ibm-research/materials.selfies-ted' }],
        inference: []
      }
    },
    {
      id: 'mhg-ged',
      slices: [],
      name: 'MHG-GED',
      organization: 'IBM Research',
      summary: 'A molecular hypergraph grammar graph neural network autoencoder for molecular structure generation and representation.',
      tasks: ['molecular generation', 'representation learning'],
      domains: ['molecules', 'materials', 'graphs'],
      tags: ['hypergraph grammar', 'autoencoder', 'graph neural network', 'molecular generation'],
      hubs: ['Hugging Face'],
      license: 'Apache-2.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'QM9 dataset', relationship: 'training data', search: 'QM9' }],
        papers: [{ label: 'MHG-GED paper', relationship: 'publication', url: 'https://doi.org/10.1080/27660400.2021.1965684' }],
        code: [{ label: 'MHG-GED model card', relationship: 'model card', url: 'https://huggingface.co/ibm-research/materials.mhg-ged' }],
        inference: []
      }
    },
    {
      id: 'pos-egnn',
      slices: [],
      name: 'POS-EGNN',
      organization: 'IBM Research',
      summary: 'An equivariant graph neural network for molecular and materials-property prediction.',
      tasks: ['property prediction', 'representation learning'],
      domains: ['molecules', 'materials', 'graphs'],
      tags: ['equivariant model', 'graph neural network', 'property prediction'],
      hubs: ['Hugging Face'],
      license: 'Apache-2.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'QM9 dataset', relationship: 'training data', search: 'QM9' }],
        papers: [{ label: 'EGNN paper', relationship: 'publication', url: 'https://arxiv.org/abs/2102.09844' }],
        code: [{ label: 'POS-EGNN model card', relationship: 'model card', url: 'https://huggingface.co/ibm-research/materials.pos-egnn' }],
        inference: []
      }
    },
    {
      id: 'omatg-mp-20-dng',
      slices: [],
      name: 'OMatG MP-20-DNG',
      organization: 'OMatG',
      summary: 'A diffusion neural generator for inorganic crystal structures in the MP-20 setting.',
      tasks: ['crystal structure generation', 'materials generation'],
      domains: ['inorganic materials', 'crystal structures'],
      tags: ['diffusion model', 'generative model', 'crystal generation'],
      hubs: ['Hugging Face'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'MP-20', relationship: 'benchmark setting', search: 'MP-20 materials dataset' }],
        papers: [{ label: 'MP-20 crystal generation paper', relationship: 'benchmark publication', url: 'https://arxiv.org/abs/2110.06197' }],
        code: [{ label: 'OMatG MP-20-DNG model card', relationship: 'model card', url: 'https://huggingface.co/OMatG/MP-20-DNG' }],
        inference: []
      }
    },
    {
      id: 'mattext',
      slices: [],
      name: 'MatText',
      organization: 'n0w0f',
      summary: 'A language model for crystal-structure text representations and materials text.',
      tasks: ['text representation', 'crystal structure generation'],
      domains: ['materials science', 'crystal structures', 'scientific text'],
      tags: ['language model', 'NLP', 'crystal text'],
      hubs: ['Hugging Face'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials Project crystal texts', relationship: 'training data', search: 'Materials Project' }],
        papers: [{ label: 'MatText preprint', relationship: 'publication', url: 'https://arxiv.org/abs/2403.14006' }],
        code: [{ label: 'MatText model card', relationship: 'model card', url: 'https://huggingface.co/n0w0f/MatText-crystal-txt-llm-2m' }],
        inference: []
      }
    },
    {
      id: 'crystallm-pi',
      slices: [],
      name: 'CrystaLLM-pi',
      organization: 'C-Bone',
      summary: 'A language-model approach to generating crystalline material structures.',
      tasks: ['crystal structure generation', 'materials generation'],
      domains: ['crystals', 'inorganic materials', 'scientific language'],
      tags: ['language model', 'generative model', 'crystal structures'],
      hubs: ['Hugging Face'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'COD crystallographic database', relationship: 'training data', search: 'Crystallography Open Database' }],
        papers: [{ label: 'CrystaLLM paper', relationship: 'publication', url: 'https://arxiv.org/abs/2307.04340' }],
        code: [{ label: 'CrystaLLM model card', relationship: 'model card', url: 'https://huggingface.co/c-bone/CrystaLLM-pi_base' }],
        inference: []
      }
    },
    {
      id: 'clari',
      slices: ["chemistry"],
      name: 'CLARI',
      organization: 'The Matter Lab',
      summary: 'A flow-matching model for organic crystal structure prediction.',
      tasks: ['organic crystal structure prediction', 'structure generation'],
      domains: ['organic crystals', 'crystal structures'],
      tags: ['flow matching', 'crystal structure prediction', 'generative model'],
      hubs: ['Hugging Face'],
      license: 'Weights CC BY-NC 4.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'CSD organic crystals', relationship: 'training data', search: 'Cambridge Structural Database' }],
        papers: [{ label: 'CLARI paper', relationship: 'publication', url: 'https://arxiv.org/abs/2606.03199' }],
        code: [{ label: 'CLARI model card', relationship: 'model card', url: 'https://huggingface.co/the-matter-lab/clari' }],
        inference: []
      }
    },
    {
      id: 'quokka',
      slices: [],
      name: 'Quokka',
      organization: 'UCSB',
      summary: 'A materials-science large-language-model chatbot for question answering.',
      tasks: ['materials-science question answering', 'chatbot'],
      domains: ['materials science', 'scientific text'],
      tags: ['large language model', 'chatbot', 'materials science'],
      hubs: ['Hugging Face'],
      license: 'Apache-2.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Materials Project crystal structures', relationship: 'training data', search: 'Materials Project' }],
        papers: [{ label: 'Quokka paper', relationship: 'publication', url: 'https://arxiv.org/abs/2401.01089' }],
        code: [{ label: 'Quokka model card', relationship: 'model card', url: 'https://huggingface.co/Xianjun/Quokka-7b-instruct' }],
        inference: []
      }
    },
    {
      id: 'kaggle-nexamat',
      slices: [],
      name: 'NexaMat',
      organization: 'Kaggle',
      summary: 'A Kaggle-hosted materials-science model for materials discovery and prediction.',
      tasks: ['materials discovery', 'property prediction'],
      domains: ['materials science', 'inorganic materials'],
      tags: ['model', 'Kaggle', 'materials discovery'],
      hubs: ['Kaggle'],
      license: 'Apache-2.0',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Kaggle materials benchmark', relationship: 'competition dataset', search: 'Kaggle materials' }],
        papers: [{ label: 'NexaMat challenge', relationship: 'competition overview', url: 'https://www.kaggle.com/competitions/nexamat' }],
        code: [{ label: 'NexaMat on Kaggle', relationship: 'model', url: 'https://www.kaggle.com/models/allanwandia/material-science' }],
        inference: []
      }
    },
    {
      id: 'kaggle-chgnet-cathode',
      slices: ["battery"],
      name: 'CHGNet cathode',
      organization: 'Kaggle',
      summary: 'A Kaggle-hosted CHGNet-based ensemble model for Li-ion cathode screening.',
      tasks: ['cathode screening', 'property prediction'],
      domains: ['battery materials', 'cathode materials'],
      tags: ['model', 'Kaggle', 'CHGNet', 'batteries'],
      hubs: ['Kaggle'],
      license: 'MIT',
      verified_on: '2026-08-13',
      resources: {
        datasets: [{ label: 'Li-ion cathode dataset', relationship: 'screening dataset', search: 'Li-ion cathode materials' }],
        papers: [{ label: 'CHGNet cathode ensemble paper', relationship: 'publication', url: 'https://arxiv.org/abs/2302.14231' }],
        code: [{ label: 'CHGNet cathode model on Kaggle', relationship: 'model', url: 'https://www.kaggle.com/models/erenar/li-ion-cathode-screeningchgnet-based-ensemble' }],
        inference: []
      }
    }
  ].freeze

  def index
    catalogue = CATALOGUE
    requested_sort = params[:Sort_by].to_s
    @sort = %w[name_asc name_desc fair_desc].include?(requested_sort) ? requested_sort : 'name_asc'
    @sort_options = SORT_OPTIONS
    @models = catalogue.select { |model| matches_filters?(model) }
    @models = case @sort
              when 'name_desc' then @models.sort_by { |model| model[:name].to_s.downcase }.reverse
              when 'fair_desc' then @models.sort_by { |model| [-self.class.fair_score_for(model)[:overall_score], model[:name].to_s.downcase] }
              else @models.sort_by { |model| model[:name].to_s.downcase }
              end
    @sections = SECTIONS
    @organization_options = catalogue.map { |model| model[:organization] }.reject { |o| o.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @task_options = catalogue.flat_map { |model| model[:tasks] }.reject { |t| t.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @domain_options = catalogue.flat_map { |model| model[:domains] }.reject { |d| d.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @hub_options = catalogue.flat_map { |model| model[:hubs] }.reject { |h| h.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @license_options = catalogue.map { |model| model[:license] }.reject { |l| l.to_s.strip.empty? }.uniq.sort_by(&:downcase)
    @selected_organization = params[:organization].to_s.strip
    @selected_task = params[:task].to_s.strip
    @selected_domain = params[:domain].to_s.strip
    @selected_hub = params[:hub].to_s.strip
    @selected_license = params[:license].to_s.strip
    render :index
  end

  def show
    @model = CATALOGUE.find { |model| model[:id] == params[:id].to_s }
    return head :not_found unless @model

    @sections = SECTIONS
    requested_section = params[:section].to_s
    @section = SECTIONS.include?(requested_section) ? requested_section : 'overview'
    @model_card = model_card_for(@model)
    @fair_score = fair_score_for(@model)
    render :show
  end

  def model_card_for(model)
    self.class.model_card_for(model)
  end

  def fair_score_for(model)
    self.class.fair_score_for(model)
  end

  def self.model_card_for(model)
    return {} unless model.is_a?(Hash)

    card = DEFAULT_MODEL_CARD.merge(model[:model_card] || {})
    org = model[:organization].to_s.strip
    card[:organization] = org.empty? ? 'Unknown' : model[:organization]
    lic = model[:license].to_s.strip
    card[:license] = lic.empty? ? 'Unknown' : model[:license]
    src = card[:source_url].to_s.strip
    card[:source_url] = if !src.empty?
                          card[:source_url]
                        elsif (code_url = model.dig(:resources, :code)&.first&.dig(:url)) && !code_url.to_s.strip.empty?
                          code_url
                        elsif (paper_url = model.dig(:resources, :papers)&.first&.dig(:url)) && !paper_url.to_s.strip.empty?
                          paper_url
                        else
                          'Not publicly documented'
                        end
    card
  end

  def self.fair_score_for(model)
    return { overall_score: 0, principles: { 'F' => 0, 'A' => 0, 'I' => 0, 'R' => 0 }, criteria: {}, profile: FAIR_PROFILE, disclaimer: FAIR_DISCLAIMER, methodology: FAIR_METHODOLOGY } unless model.is_a?(Hash)

    card = model_card_for(model)
    resources = model[:resources] || {}
    hubs = Array(model[:hubs]).reject { |h| h.to_s.strip.empty? }
    domains = Array(model[:domains]).reject { |d| d.to_s.strip.empty? }
    tasks = Array(model[:tasks]).reject { |t| t.to_s.strip.empty? }
    tags = Array(model[:tags]).reject { |tg| tg.to_s.strip.empty? }
    code_links = Array(resources[:code])
    paper_links = Array(resources[:papers])
    dataset_links = Array(resources[:datasets])
    all_resource_links = code_links + paper_links + dataset_links + Array(resources[:inference])

    # F: Findable (0-100)
    f_criteria = [
      { id: 'F1', label: 'Unique identifier & canonical title', pass: !model[:id].to_s.strip.empty? && !model[:name].to_s.strip.empty? },
      { id: 'F2', label: 'Summary description of scope and capabilities', pass: !model[:summary].to_s.strip.empty? },
      { id: 'F3', label: 'Discoverability task keywords or domain tags', pass: tasks.any? || tags.any? },
      { id: 'F4', label: 'Attributed creator organization or institution', pass: !model[:organization].to_s.strip.empty? && model[:organization] != 'Unknown' }
    ]
    f_score = (f_criteria.count { |c| c[:pass] } / f_criteria.length.to_f * 100).round

    # A: Accessible (0-100)
    a_criteria = [
      { id: 'A1', label: 'Primary code repository or model card HTTPS link', pass: code_links.any? { |c| c[:url].to_s.start_with?('https://') } },
      { id: 'A2', label: 'Public HTTPS resource link (code, paper, dataset, or inference)', pass: all_resource_links.any? { |r| r[:url].to_s.start_with?('https://') } },
      { id: 'A3', label: 'Peer-reviewed publication or preprint reference', pass: paper_links.any? { |p| p[:url].to_s.start_with?('https://') } },
      { id: 'A4', label: 'Identified hub distribution platform', pass: hubs.any? }
    ]
    a_score = (a_criteria.count { |c| c[:pass] } / a_criteria.length.to_f * 100).round

    # I: Interoperable (0-100)
    i_criteria = [
      { id: 'I1', label: 'Catalogued materials or molecular domain labels', pass: domains.any? },
      { id: 'I2', label: 'Linked training or evaluation reference datasets', pass: dataset_links.any? },
      { id: 'I3', label: 'Documented architecture or framework metadata', pass: card[:architecture] != 'Unknown' || card[:framework] != 'Unknown' },
      { id: 'I4', label: 'Documented input or output modalities', pass: card[:inputs] != 'Unknown' || card[:outputs] != 'Unknown' }
    ]
    i_score = (i_criteria.count { |c| c[:pass] } / i_criteria.length.to_f * 100).round

    # R: Reusable (0-100)
    r_criteria = [
      { id: 'R1', label: 'Declared licence or access-terms field', pass: !model[:license].to_s.strip.empty? && model[:license] != 'Unknown' },
      { id: 'R2', label: 'Verified curation timestamp currency', pass: !model[:verified_on].to_s.strip.empty? },
      { id: 'R3', label: 'Documented version or checkpoint release', pass: card[:version] != 'Unknown' && !card[:version].to_s.strip.empty? },
      { id: 'R4', label: 'Linked implementation or publication resource', pass: code_links.any? { |c| c[:url].to_s.start_with?('https://') } || paper_links.any? { |p| p[:url].to_s.start_with?('https://') } }
    ]
    r_score = (r_criteria.count { |c| c[:pass] } / r_criteria.length.to_f * 100).round

    overall = ((f_score + a_score + i_score + r_score) / 4.0).round

    {
      overall_score: overall,
      principles: {
        'F' => f_score,
        'A' => a_score,
        'I' => i_score,
        'R' => r_score
      },
      criteria: {
        'Findable' => f_criteria,
        'Accessible' => a_criteria,
        'Interoperable' => i_criteria,
        'Reusable' => r_criteria
      },
      profile: FAIR_PROFILE,
      disclaimer: FAIR_DISCLAIMER,
      methodology: FAIR_METHODOLOGY
    }
  end

  private

  def require_models_catalogue
    head :not_found unless Flipper.enabled?(:models_catalogue)
  end

  def matches_filters?(model)
    search = params[:search].to_s.strip.downcase
    organization = params[:organization].to_s.strip.downcase
    task = params[:task].to_s.strip.downcase
    domain = params[:domain].to_s.strip.downcase
    hub = params[:hub].to_s.strip.downcase
    license = params[:license].to_s.strip.downcase
    haystack = [
      model[:id],
      model[:name],
      model[:organization],
      model[:summary],
      model[:tasks],
      model[:domains],
      model[:tags],
      model[:hubs],
      model[:license]
    ].flatten.compact.join(' ').downcase

    (search.empty? || haystack.include?(search)) &&
      (organization.empty? || model[:organization].to_s.downcase == organization) &&
      (task.empty? || Array(model[:tasks]).any? { |value| value.to_s.downcase == task }) &&
      (domain.empty? || Array(model[:domains]).any? { |value| value.to_s.downcase == domain }) &&
      (hub.empty? || Array(model[:hubs]).any? { |value| value.to_s.downcase == hub }) &&
      (license.empty? || model[:license].to_s.downcase == license)
  end
end
