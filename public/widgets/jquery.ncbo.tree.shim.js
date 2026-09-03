/**
 * jQuery NCBO Tree Backward-Compatibility Shim
 * Translates legacy $.fn.NCBOTree calls into native <ontoportal-tree> Custom Element instances.
 */

(function($) {
  if (!$) {
    if (typeof jQuery !== 'undefined') $ = jQuery;
    else return;
  }

  // Load modern widgets bundle if not yet present
  function ensureModernWidgetsLoaded() {
    if (customElements.get('ontoportal-tree')) {
      return Promise.resolve();
    }
    return new Promise(function(resolve, reject) {
      var script = document.createElement('script');
      script.src = '/widgets/modern/ontoportal-widgets.js';
      script.async = true;
      script.onload = resolve;
      script.onerror = reject;
      document.head.appendChild(script);
    });
  }

  $.fn.NCBOTree = function(options) {
    options = options || {};
    var $targets = this;

    ensureModernWidgetsLoaded().then(function() {
      $targets.each(function() {
        var container = this;
        container.innerHTML = '';

        var treeEl = document.createElement('ontoportal-tree');
        if (options.ncboAPIURL) treeEl.setAttribute('api-url', options.ncboAPIURL);
        if (options.apikey) treeEl.setAttribute('api-key', options.apikey);
        if (options.ontology) treeEl.setAttribute('ontology', options.ontology);
        if (options.startingClass) treeEl.setAttribute('starting-class', options.startingClass);
        treeEl.setAttribute('searchable', options.searchable !== false ? 'true' : 'false');

        // Event bridging
        if (typeof options.afterSelect === 'function') {
          treeEl.addEventListener('ontoportal:node-selected', function(e) {
            options.afterSelect(e.detail.nodeId, e.detail.concept);
          });
        }
        if (typeof options.afterExpand === 'function') {
          treeEl.addEventListener('ontoportal:node-expanded', function(e) {
            options.afterExpand(e.detail.nodeId, e.detail.concept);
          });
        }

        container.appendChild(treeEl);

        // Store tree reference for chained calls
        $(container).data('NCBOTree', {
          element: treeEl,
          selectClass: function(classId) {
            treeEl.selectNode(classId);
          },
          jumpToClass: function(classId) {
            treeEl.expandNode(classId);
            treeEl.selectNode(classId);
          }
        });
      });
    });

    return this;
  };
})(typeof jQuery !== 'undefined' ? jQuery : null);
