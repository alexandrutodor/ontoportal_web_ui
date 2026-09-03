# frozen_string_literal: true

module RecommenderHelper
  def license_badge(spdx, permissive)
    label = spdx.presence || 'Unknown'
    css = permissive ? 'badge bg-success text-white' : 'badge bg-secondary text-white'
    content_tag(:span, label, class: css, title: permissive ? 'Permissive Open License' : 'Restricted or Unspecified License')
  end

  def pareto_rank_badge(rank)
    case rank.to_i
    when 1
      content_tag(:span, 'Front 1 (Optimal)', class: 'badge bg-primary text-white font-weight-bold')
    when 2
      content_tag(:span, 'Front 2', class: 'badge bg-info text-white')
    when 3
      content_tag(:span, 'Front 3', class: 'badge bg-light text-dark border')
    else
      content_tag(:span, "Front #{rank}", class: 'badge bg-light text-muted border')
    end
  end

  def format_metric_percentage(val)
    return '0.0%' if val.nil? || val.to_f.zero?
    sprintf('%.1f%%', val.to_f * 100.0)
  end
end
