/**
 * OntoPortal Modern Widgets Entry Point
 * Exports OntoPortalClient and registers custom elements:
 * - <ontoportal-autocomplete>
 * - <ontoportal-tree>
 * - <ontoportal-concept-card>
 */

import { OntoPortalClient, OntoPortalError } from './sdk/ontoportal_client.js';
import { OntoPortalAutocomplete } from './components/widgets/ontoportal_autocomplete.js';
import { OntoPortalTree } from './components/widgets/ontoportal_tree.js';
import { OntoPortalConceptCard } from './components/widgets/ontoportal_concept_card.js';

// Auto-register custom elements if not already defined
if (typeof customElements !== 'undefined') {
  if (!customElements.get('ontoportal-autocomplete')) {
    customElements.define('ontoportal-autocomplete', OntoPortalAutocomplete);
  }
  if (!customElements.get('ontoportal-tree')) {
    customElements.define('ontoportal-tree', OntoPortalTree);
  }
  if (!customElements.get('ontoportal-concept-card')) {
    customElements.define('ontoportal-concept-card', OntoPortalConceptCard);
  }
}

// Global browser attachment
if (typeof window !== 'undefined') {
  window.OntoPortal = window.OntoPortal || {};
  window.OntoPortal.Client = OntoPortalClient;
  window.OntoPortal.Error = OntoPortalError;
  window.OntoPortal.Autocomplete = OntoPortalAutocomplete;
  window.OntoPortal.Tree = OntoPortalTree;
  window.OntoPortal.ConceptCard = OntoPortalConceptCard;
}

export {
  OntoPortalClient,
  OntoPortalError,
  OntoPortalAutocomplete,
  OntoPortalTree,
  OntoPortalConceptCard
};
