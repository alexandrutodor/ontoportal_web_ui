(()=>{var v=Object.defineProperty;var E=(l,e,t)=>e in l?v(l,e,{enumerable:!0,configurable:!0,writable:!0,value:t}):l[e]=t;var x=(l,e,t)=>(E(l,typeof e!="symbol"?e+"":e,t),t);var h=class extends Error{constructor(e,t=500,o=null){super(e),this.name="OntoPortalError",this.status=t,this.details=o}},y=class{constructor(e=200){this.maxSize=e,this.cache=new Map}get(e){if(!this.cache.has(e))return;let t=this.cache.get(e);return this.cache.delete(e),this.cache.set(e,t),t}set(e,t){if(this.cache.has(e))this.cache.delete(e);else if(this.cache.size>=this.maxSize){let o=this.cache.keys().next().value;this.cache.delete(o)}this.cache.set(e,t)}clear(){this.cache.clear()}},c=class{constructor(e={}){this.apiURL=(e.apiURL||"").replace(/\/+$/,""),this.apiKey=e.apiKey||"",this.uiURL=(e.uiURL||"").replace(/\/+$/,""),this.timeout=e.timeout||15e3,this.cache=new y(e.cacheSize||200)}_buildURL(e,t={}){let i=/^https?:\/\//i.test(e)?e:`${this.apiURL}${e.startsWith("/")?e:"/"+e}`,s=new URL(i,typeof window<"u"&&window.location?window.location.origin:"http://localhost");return this.apiKey&&!s.searchParams.has("apikey")&&s.searchParams.set("apikey",this.apiKey),Object.entries(t).forEach(([n,r])=>{r!=null&&r!==""&&s.searchParams.set(n,r)}),s.toString()}async _fetch(e,t={}){let o=e;if(t.useCache!==!1&&(!t.method||t.method==="GET")){let a=this.cache.get(o);if(a)return a}let i=new AbortController,s=setTimeout(()=>i.abort(),t.timeout||this.timeout),n=i.signal;t.signal&&t.signal.addEventListener("abort",()=>i.abort());let r={Accept:"application/json",...t.headers||{}};this.apiKey&&!r.Authorization&&(r.Authorization=`apikey token=${this.apiKey}`);try{let a=await fetch(e,{method:t.method||"GET",headers:r,signal:n,body:t.body});if(clearTimeout(s),!a.ok){let m=`HTTP ${a.status} ${a.statusText}`,d=null;try{d=await a.json(),d&&(d.error||d.message)&&(m=d.error||d.message)}catch{}throw new h(m,a.status,d)}let p=await a.json();return t.useCache!==!1&&(!t.method||t.method==="GET")&&this.cache.set(o,p),p}catch(a){throw clearTimeout(s),a.name==="AbortError"?new h("Request timed out or aborted",408):a instanceof h?a:new h(a.message,500,a)}}async search(e,t={}){if(!e||!e.trim())return{collection:[],page:1,pageCount:0};let o={q:e.trim(),ontologies:t.ontologies||"",pagesize:t.pageSize||t.pagesize||25,page:t.page||1,require_exact:t.requireExact?"true":"false",include:t.include||"prefLabel,synonym,definition,obsolete,subClassOf"},i=this._buildURL("/search",o);return await this._fetch(i,t)}async getRoots(e,t={}){let o=encodeURIComponent(e),i={include:t.include||"prefLabel,hasChildren,subClassOf,obsolete"},s=this._buildURL(`/ontologies/${o}/classes/roots`,i);return await this._fetch(s,t)}async getChildren(e,t,o={}){let i=encodeURIComponent(e),s=encodeURIComponent(t),n={include:o.include||"prefLabel,hasChildren,subClassOf,obsolete"},r=this._buildURL(`/ontologies/${i}/classes/${s}/children`,n);return await this._fetch(r,o)}async getParents(e,t,o={}){let i=encodeURIComponent(e),s=encodeURIComponent(t),n=this._buildURL(`/ontologies/${i}/classes/${s}/parents`);return await this._fetch(n,o)}async getClass(e,t,o={}){let i=encodeURIComponent(e),s=encodeURIComponent(t),n={include:o.include||"prefLabel,synonym,definition,properties,subClassOf,hasChildren,obsolete"},r=this._buildURL(`/ontologies/${i}/classes/${s}`,n);return await this._fetch(r,o)}async getOntology(e,t={}){let o=encodeURIComponent(e),i=this._buildURL(`/ontologies/${o}`);return await this._fetch(i,t)}clearCache(){this.cache.clear()}};var u=class extends HTMLElement{static get observedAttributes(){return["api-url","api-key","ontologies","value-field","placeholder","debounce-ms","name","disabled","required","value"]}constructor(){super(),this.attachInternals&&(this._internals=this.attachInternals()),this.attachShadow({mode:"open"}),this._client=null,this._value="",this._selectedConcept=null,this._results=[],this._activeIndex=-1,this._debounceTimer=null,this._abortController=null,this._onInput=this._onInput.bind(this),this._onKeyDown=this._onKeyDown.bind(this),this._onFocus=this._onFocus.bind(this),this._onBlur=this._onBlur.bind(this),this._onClearClick=this._onClearClick.bind(this)}connectedCallback(){this._initClient(),this._render(),this._syncLightDomInputs()}disconnectedCallback(){clearTimeout(this._debounceTimer),this._abortController&&this._abortController.abort()}attributeChangedCallback(e,t,o){t!==o&&(e==="api-url"||e==="api-key"?this._initClient():e==="value"?(this._value=o||"",this._inputEl&&(this._inputEl.value=this._value),this._internals&&this._internals.setFormValue(this._value)):e==="placeholder"&&this._inputEl?this._inputEl.placeholder=o:e==="disabled"&&this._inputEl&&(this._inputEl.disabled=this.hasAttribute("disabled")))}get form(){return this._internals?this._internals.form:null}get name(){return this.getAttribute("name")||""}set name(e){this.setAttribute("name",e)}get value(){return this._value}set value(e){this._value=e||"",this.setAttribute("value",this._value),this._inputEl&&(this._inputEl.value=this._value),this._internals&&this._internals.setFormValue(this._value),this._syncLightDomInputs()}get selectedConcept(){return this._selectedConcept}_initClient(){let e=this.getAttribute("api-url")||typeof window<"u"&&window.ONTOPORTAL_API_URL||"",t=this.getAttribute("api-key")||typeof window<"u"&&window.ONTOPORTAL_API_KEY||"";this._client=new c({apiURL:e,apiKey:t})}_syncLightDomInputs(){let e=this.getAttribute("name");if(!e)return;let t=this._selectedConcept||{};[{id:`${e}_bioportal_preferred_name`,value:t.prefLabel||""},{id:`${e}_bioportal_concept_id`,value:t["@id"]||t.id||this._value||""},{id:`${e}_bioportal_ontology_id`,value:t.links?.ontology?t.links.ontology.split("/").pop():this.getAttribute("ontologies")||""},{id:`${e}_bioportal_full_id`,value:t["@id"]||t.id||""}].forEach(({id:i,value:s})=>{let n=this.querySelector(`input#${i}`);n||(n=document.createElement("input"),n.type="hidden",n.id=i,n.name=i,this.appendChild(n)),n.value=s})}_render(){let e=this.getAttribute("placeholder")||"Search classes...",t=this.hasAttribute("disabled");this.shadowRoot.innerHTML=`
      <style>
        :host {
          display: block;
          position: relative;
          font-family: var(--op-font-family, system-ui, -apple-system, sans-serif);
          font-size: 14px;
          color: var(--op-text-color, #1e293b);
          box-sizing: border-box;
        }
        *, *::before, *::after {
          box-sizing: inherit;
        }
        .op-combobox {
          position: relative;
          width: 100%;
        }
        .op-input-wrapper {
          display: flex;
          align-items: center;
          border: 1px solid var(--op-border-color, #cbd5e1);
          border-radius: 6px;
          background: var(--op-bg-color, #ffffff);
          transition: border-color 0.15s ease, box-shadow 0.15s ease;
          padding: 0 8px;
        }
        .op-input-wrapper:focus-within {
          border-color: var(--op-primary-color, #1a7f5a);
          box-shadow: 0 0 0 3px rgba(26, 127, 90, 0.15);
        }
        .op-input {
          flex: 1;
          border: none;
          outline: none;
          background: transparent;
          font-family: inherit;
          font-size: inherit;
          color: inherit;
          padding: 8px 4px;
          min-width: 0;
        }
        .op-input:disabled {
          cursor: not-allowed;
          opacity: 0.6;
        }
        .op-clear-btn {
          background: none;
          border: none;
          cursor: pointer;
          font-size: 16px;
          color: #94a3b8;
          padding: 2px 6px;
          line-height: 1;
          display: none;
        }
        .op-clear-btn:hover {
          color: #475569;
        }
        .op-clear-btn.visible {
          display: block;
        }
        .op-spinner {
          display: none;
          width: 14px;
          height: 14px;
          border: 2px solid #e2e8f0;
          border-top-color: var(--op-primary-color, #1a7f5a);
          border-radius: 50%;
          animation: op-spin 0.6s linear infinite;
          margin-right: 4px;
        }
        .op-spinner.loading {
          display: inline-block;
        }
        @keyframes op-spin {
          to { transform: rotate(360deg); }
        }
        .op-dropdown {
          position: absolute;
          top: calc(100% + 4px);
          left: 0;
          right: 0;
          max-height: 280px;
          overflow-y: auto;
          background: var(--op-bg-color, #ffffff);
          border: 1px solid var(--op-border-color, #cbd5e1);
          border-radius: 6px;
          box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
          z-index: 1000;
          display: none;
          list-style: none;
          margin: 0;
          padding: 4px 0;
        }
        .op-dropdown.open {
          display: block;
        }
        .op-option {
          padding: 8px 12px;
          cursor: pointer;
          display: flex;
          flex-direction: column;
          gap: 2px;
          transition: background-color 0.1s ease;
        }
        .op-option:hover, .op-option.active {
          background-color: #f1f5f9;
        }
        .op-option-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          font-weight: 500;
        }
        .op-option-label {
          color: var(--op-text-color, #1e293b);
        }
        .op-option-ontology {
          font-size: 11px;
          font-weight: 600;
          padding: 1px 6px;
          border-radius: 4px;
          background: #e2e8f0;
          color: #475569;
        }
        .op-option-uri {
          font-size: 11px;
          color: #64748b;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .op-no-results, .op-error {
          padding: 10px 12px;
          color: #64748b;
          font-style: italic;
          text-align: center;
        }
        .op-error {
          color: #dc2626;
        }
      </style>

      <div class="op-combobox">
        <div class="op-input-wrapper">
          <input
            type="text"
            class="op-input"
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="false"
            aria-haspopup="listbox"
            placeholder="${e}"
            ${t?"disabled":""}
            value="${this._value}"
          />
          <div class="op-spinner" aria-hidden="true"></div>
          <button type="button" class="op-clear-btn" aria-label="Clear selection">&times;</button>
        </div>
        <ul class="op-dropdown" role="listbox" aria-label="Ontology search results"></ul>
      </div>
    `,this._inputEl=this.shadowRoot.querySelector(".op-input"),this._dropdownEl=this.shadowRoot.querySelector(".op-dropdown"),this._spinnerEl=this.shadowRoot.querySelector(".op-spinner"),this._clearBtn=this.shadowRoot.querySelector(".op-clear-btn"),this._inputEl.addEventListener("input",this._onInput),this._inputEl.addEventListener("keydown",this._onKeyDown),this._inputEl.addEventListener("focus",this._onFocus),this._inputEl.addEventListener("blur",this._onBlur),this._clearBtn.addEventListener("click",this._onClearClick),this._value&&this._clearBtn.classList.add("visible")}_onInput(e){let t=e.target.value;if(this._value=t,this._clearBtn.classList.toggle("visible",t.length>0),clearTimeout(this._debounceTimer),!t||t.trim().length<2){this._closeDropdown();return}let o=parseInt(this.getAttribute("debounce-ms")||"250",10);this._debounceTimer=setTimeout(()=>this._executeSearch(t),o)}async _executeSearch(e){this._abortController&&this._abortController.abort(),this._abortController=new AbortController,this._spinnerEl.classList.add("loading");try{let t=this.getAttribute("ontologies")||"",o=await this._client.search(e,{ontologies:t,pageSize:15,signal:this._abortController.signal});this._results=o&&o.collection?o.collection:[],this._renderDropdown()}catch(t){if(t.status===408||t.name==="AbortError")return;this._renderError(t.message||"Error searching classes")}finally{this._spinnerEl.classList.remove("loading")}}_renderDropdown(){if(this._dropdownEl.innerHTML="",this._activeIndex=-1,this._results.length===0){let e=document.createElement("li");e.className="op-no-results",e.textContent="No matching classes found",this._dropdownEl.appendChild(e),this._openDropdown();return}this._results.forEach((e,t)=>{let o=document.createElement("li");o.className="op-option",o.setAttribute("role","option"),o.setAttribute("id",`op-option-${t}`),o.dataset.index=t;let i=e.links?.ontology?e.links.ontology.split("/").pop():"",s=e.prefLabel||e.name||e["@id"],n=e["@id"]||e.id||"";o.innerHTML=`
        <div class="op-option-header">
          <span class="op-option-label">${s}</span>
          ${i?`<span class="op-option-ontology">${i}</span>`:""}
        </div>
        <div class="op-option-uri">${n}</div>
      `,o.addEventListener("mousedown",r=>{r.preventDefault(),this._selectItem(t)}),this._dropdownEl.appendChild(o)}),this._openDropdown()}_renderError(e){this._dropdownEl.innerHTML=`<li class="op-error">${e}</li>`,this._openDropdown()}_openDropdown(){this._dropdownEl.classList.add("open"),this._inputEl.setAttribute("aria-expanded","true")}_closeDropdown(){this._dropdownEl.classList.remove("open"),this._inputEl.setAttribute("aria-expanded","false"),this._inputEl.removeAttribute("aria-activedescendant"),this._activeIndex=-1}_onKeyDown(e){if(!this._dropdownEl.classList.contains("open")){(e.key==="ArrowDown"||e.key==="Enter")&&this._onInput({target:this._inputEl});return}let t=this.shadowRoot.querySelectorAll(".op-option");t.length!==0&&(e.key==="ArrowDown"?(e.preventDefault(),this._activeIndex=(this._activeIndex+1)%t.length,this._highlightOption(t)):e.key==="ArrowUp"?(e.preventDefault(),this._activeIndex=(this._activeIndex-1+t.length)%t.length,this._highlightOption(t)):e.key==="Enter"?(e.preventDefault(),this._activeIndex>=0&&this._activeIndex<t.length&&this._selectItem(this._activeIndex)):e.key==="Escape"&&this._closeDropdown())}_highlightOption(e){e.forEach((t,o)=>{let i=o===this._activeIndex;t.classList.toggle("active",i),t.setAttribute("aria-selected",i?"true":"false"),i&&(t.scrollIntoView({block:"nearest"}),this._inputEl.setAttribute("aria-activedescendant",t.id))})}_selectItem(e){let t=this._results[e];if(!t)return;this._selectedConcept=t;let o=this.getAttribute("value-field")||"uri",i=t["@id"]||t.id;o==="shortid"?i=(t["@id"]||t.id||"").split("/").pop().split("#").pop():o==="name"&&(i=t.prefLabel||t.name||i),this.value=i,this._inputEl.value=i,this._clearBtn.classList.add("visible"),this._closeDropdown(),this._syncLightDomInputs(),this.dispatchEvent(new CustomEvent("ontoportal:select",{bubbles:!0,composed:!0,detail:{concept:t,value:i,valueField:o}}))}_onClearClick(){this.value="",this._selectedConcept=null,this._inputEl.value="",this._clearBtn.classList.remove("visible"),this._closeDropdown(),this._syncLightDomInputs(),this.dispatchEvent(new CustomEvent("ontoportal:clear",{bubbles:!0,composed:!0})),this._inputEl.focus()}_onFocus(){this._results.length>0&&this._inputEl.value.trim().length>=2&&this._openDropdown()}_onBlur(){setTimeout(()=>this._closeDropdown(),150)}};x(u,"formAssociated",!0);typeof customElements<"u"&&!customElements.get("ontoportal-autocomplete")&&customElements.define("ontoportal-autocomplete",u);function w(l){return typeof CSS<"u"&&CSS.escape?CSS.escape(l):encodeURIComponent(l)}var f=class extends HTMLElement{static get observedAttributes(){return["api-url","api-key","ontology","starting-class","selectable","searchable","theme"]}constructor(){super(),this.attachShadow({mode:"open"}),this._client=null,this._nodes=new Map,this._selectedId=null,this._focusedId=null,this._rootIds=[],this._onTreeKeyDown=this._onTreeKeyDown.bind(this),this._onSearchInput=this._onSearchInput.bind(this)}connectedCallback(){this._initClient(),this._render(),this.reload()}attributeChangedCallback(e,t,o){t!==o&&(e==="api-url"||e==="api-key"?this._initClient():e==="ontology"&&this.reload())}_initClient(){let e=this.getAttribute("api-url")||typeof window<"u"&&window.ONTOPORTAL_API_URL||"",t=this.getAttribute("api-key")||typeof window<"u"&&window.ONTOPORTAL_API_KEY||"";this._client=new c({apiURL:e,apiKey:t})}async reload(){let e=this.getAttribute("ontology");if(!(!e||!this._client||!this._containerEl)){this._nodes.clear(),this._rootIds=[],this._selectedId=null,this._focusedId=null,this._setLoading(!0);try{let t=this.getAttribute("starting-class");if(t){let o=await this._client.getClass(e,t),i=o["@id"]||o.id;this._nodes.set(i,{...o,id:i,label:o.prefLabel||o.name||i,expanded:!0,loaded:!1,children:[]}),this._rootIds=[i],await this._loadNodeChildren(i)}else{let o=await this._client.getRoots(e),i=Array.isArray(o)?o:o.collection||[];this._rootIds=i.map(s=>{let n=s["@id"]||s.id;return this._nodes.set(n,{...s,id:n,label:s.prefLabel||s.name||n,expanded:!1,loaded:!1,children:[]}),n})}this._renderTree()}catch(t){this._renderError(t.message||"Failed to load ontology hierarchy")}finally{this._setLoading(!1)}}}async _loadNodeChildren(e){let t=this._nodes.get(e);if(!t||t.loaded)return;let o=this.getAttribute("ontology");try{t.loading=!0,this._updateNodeDOM(e);let i=await this._client.getChildren(o,e),s=Array.isArray(i)?i:i.collection||[];t.children=s.map(n=>{let r=n["@id"]||n.id;return this._nodes.has(r)||this._nodes.set(r,{...n,id:r,parentId:e,label:n.prefLabel||n.name||r,expanded:!1,loaded:!1,children:[]}),r}),t.loaded=!0,t.hasChildren=t.children.length>0}catch(i){console.error(`Failed to load children for ${e}:`,i),t.error=i.message}finally{t.loading=!1,this._updateNodeDOM(e)}}_render(){let e=this.getAttribute("searchable")!=="false";this.shadowRoot.innerHTML=`
      <style>
        :host {
          display: block;
          font-family: var(--op-font-family, system-ui, -apple-system, sans-serif);
          font-size: 14px;
          color: var(--op-text-color, #1e293b);
          background: var(--op-bg-color, #ffffff);
          border: 1px solid var(--op-border-color, #e2e8f0);
          border-radius: 8px;
          padding: 12px;
          box-sizing: border-box;
          max-height: var(--op-tree-max-height, 500px);
          overflow-y: auto;
        }
        *, *::before, *::after {
          box-sizing: inherit;
        }
        .op-tree-search {
          margin-bottom: 10px;
          position: relative;
        }
        .op-tree-search-input {
          width: 100%;
          padding: 6px 10px;
          border: 1px solid var(--op-border-color, #cbd5e1);
          border-radius: 6px;
          font-size: 13px;
          outline: none;
        }
        .op-tree-search-input:focus {
          border-color: var(--op-primary-color, #1a7f5a);
          box-shadow: 0 0 0 2px rgba(26, 127, 90, 0.15);
        }
        .op-tree-container {
          list-style: none;
          margin: 0;
          padding: 0;
        }
        .op-tree-node {
          list-style: none;
          margin: 0;
          padding: 0;
        }
        .op-node-row {
          display: flex;
          align-items: center;
          gap: 6px;
          padding: 4px 6px;
          border-radius: 4px;
          cursor: pointer;
          user-select: none;
          transition: background 0.1s ease;
        }
        .op-node-row:hover {
          background: #f1f5f9;
        }
        .op-node-row.selected {
          background: #e6f4ea;
          color: #0d6832;
          font-weight: 500;
        }
        .op-node-row:focus-visible, .op-node-row.focused {
          outline: 2px solid var(--op-primary-color, #1a7f5a);
          outline-offset: -1px;
        }
        .op-toggle-btn {
          width: 18px;
          height: 18px;
          display: inline-flex;
          align-items: center;
          justify-content: center;
          border: none;
          background: none;
          cursor: pointer;
          font-size: 10px;
          color: #64748b;
          border-radius: 3px;
          padding: 0;
          line-height: 1;
        }
        .op-toggle-btn:hover {
          background: #e2e8f0;
          color: #1e293b;
        }
        .op-toggle-placeholder {
          width: 18px;
          height: 18px;
          display: inline-block;
        }
        .op-node-icon {
          font-size: 12px;
          color: #94a3b8;
        }
        .op-node-label {
          flex: 1;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .op-node-children {
          list-style: none;
          margin: 0;
          padding-left: 18px;
          display: none;
        }
        .op-node-children.expanded {
          display: block;
        }
        .op-spinner {
          width: 12px;
          height: 12px;
          border: 2px solid #cbd5e1;
          border-top-color: #1a7f5a;
          border-radius: 50%;
          animation: op-spin 0.6s linear infinite;
        }
        @keyframes op-spin {
          to { transform: rotate(360deg); }
        }
        .op-tree-loading, .op-tree-error, .op-tree-empty {
          padding: 16px;
          text-align: center;
          color: #64748b;
          font-size: 13px;
        }
        .op-tree-error {
          color: #dc2626;
        }
      </style>

      ${e?`
        <div class="op-tree-search">
          <input type="text" class="op-tree-search-input" placeholder="Filter tree..." aria-label="Filter tree nodes" />
        </div>
      `:""}

      <div class="op-tree-wrapper">
        <ul class="op-tree-container" role="tree" tabindex="0" aria-label="Ontology Tree"></ul>
      </div>
    `,this._containerEl=this.shadowRoot.querySelector(".op-tree-container"),this._containerEl.addEventListener("keydown",this._onTreeKeyDown),e&&this.shadowRoot.querySelector(".op-tree-search-input").addEventListener("input",this._onSearchInput)}_setLoading(e){!this._containerEl||e&&(this._containerEl.innerHTML='<div class="op-tree-loading"><div class="op-spinner" style="display:inline-block; margin-right:8px;"></div>Loading hierarchy...</div>')}_renderError(e){!this._containerEl||(this._containerEl.innerHTML=`<div class="op-tree-error">${e}</div>`)}_renderTree(){if(this._containerEl.innerHTML="",this._rootIds.length===0){this._containerEl.innerHTML='<div class="op-tree-empty">No root classes available.</div>';return}this._rootIds.forEach(e=>{let t=this._createNodeElement(e);this._containerEl.appendChild(t)}),this._rootIds.length>0&&!this._focusedId&&(this._focusedId=this._rootIds[0])}_createNodeElement(e){let t=this._nodes.get(e);if(!t)return document.createElement("li");let o=document.createElement("li");o.className="op-tree-node",o.setAttribute("role","treeitem"),o.setAttribute("id",`op-tree-${w(e)}`),o.setAttribute("aria-selected",this._selectedId===e?"true":"false"),o.setAttribute("aria-expanded",t.hasChildren!==!1&&t.expanded?"true":"false");let i=document.createElement("div");if(i.className=`op-node-row ${this._selectedId===e?"selected":""} ${this._focusedId===e?"focused":""}`,i.dataset.id=e,t.hasChildren!==!1){let a=document.createElement("button");a.className="op-toggle-btn",a.setAttribute("aria-label",t.expanded?"Collapse node":"Expand node"),a.innerHTML=t.loading?'<div class="op-spinner"></div>':t.expanded?"&#x25BC;":"&#x25B6;",a.addEventListener("click",p=>{p.stopPropagation(),this.toggleNode(e)}),i.appendChild(a)}else{let a=document.createElement("span");a.className="op-toggle-placeholder",i.appendChild(a)}let n=document.createElement("span");n.className="op-node-label",n.textContent=t.label||e,i.appendChild(n),i.addEventListener("click",()=>{this.selectNode(e)}),o.appendChild(i);let r=document.createElement("ul");return r.className=`op-node-children ${t.expanded?"expanded":""}`,r.setAttribute("role","group"),t.expanded&&t.children&&t.children.length>0&&t.children.forEach(a=>{r.appendChild(this._createNodeElement(a))}),o.appendChild(r),o}_updateNodeDOM(e){let t=this.shadowRoot.getElementById(`op-tree-${w(e)}`);if(!t)return;let o=this._createNodeElement(e);t.replaceWith(o)}async toggleNode(e){let t=this._nodes.get(e);!t||(t.expanded?(t.expanded=!1,this._updateNodeDOM(e),this.dispatchEvent(new CustomEvent("ontoportal:node-collapsed",{bubbles:!0,composed:!0,detail:{nodeId:e,node:t}}))):(t.expanded=!0,t.loaded?this._updateNodeDOM(e):await this._loadNodeChildren(e),this.dispatchEvent(new CustomEvent("ontoportal:node-expanded",{bubbles:!0,composed:!0,detail:{nodeId:e,node:t}}))))}async expandNode(e){let t=this._nodes.get(e);t&&!t.expanded&&await this.toggleNode(e)}collapseNode(e){let t=this._nodes.get(e);t&&t.expanded&&this.toggleNode(e)}selectNode(e){let t=this._nodes.get(e);!t||(this._selectedId=e,this._focusedId=e,this.shadowRoot.querySelectorAll(".op-node-row").forEach(o=>{let i=o.dataset.id===e;o.classList.toggle("selected",i),o.classList.toggle("focused",i)}),this.dispatchEvent(new CustomEvent("ontoportal:node-selected",{bubbles:!0,composed:!0,detail:{nodeId:e,concept:t}})))}_onTreeKeyDown(e){if(!this._focusedId)return;let t=Array.from(this.shadowRoot.querySelectorAll(".op-node-row")),o=t.findIndex(i=>i.dataset.id===this._focusedId);if(o!==-1)if(e.key==="ArrowDown"){e.preventDefault();let i=Math.min(o+1,t.length-1);this._focusRow(t[i])}else if(e.key==="ArrowUp"){e.preventDefault();let i=Math.max(o-1,0);this._focusRow(t[i])}else if(e.key==="ArrowRight"){e.preventDefault();let i=this._nodes.get(this._focusedId);i&&!i.expanded&&i.hasChildren!==!1&&this.toggleNode(this._focusedId)}else if(e.key==="ArrowLeft"){e.preventDefault();let i=this._nodes.get(this._focusedId);if(i&&i.expanded)this.toggleNode(this._focusedId);else if(i&&i.parentId){let s=t.find(n=>n.dataset.id===i.parentId);s&&this._focusRow(s)}}else(e.key==="Enter"||e.key===" ")&&(e.preventDefault(),this.selectNode(this._focusedId))}_focusRow(e){!e||(this._focusedId=e.dataset.id,this.shadowRoot.querySelectorAll(".op-node-row").forEach(t=>t.classList.remove("focused")),e.classList.add("focused"),e.scrollIntoView({block:"nearest"}))}_onSearchInput(e){let t=e.target.value.toLowerCase().trim();this.shadowRoot.querySelectorAll(".op-node-row").forEach(i=>{let s=i.querySelector(".op-node-label")?.textContent.toLowerCase()||"",n=!t||s.includes(t),r=i.closest("li.op-tree-node");r&&(r.style.display=n?"":"none")})}};typeof customElements<"u"&&!customElements.get("ontoportal-tree")&&customElements.define("ontoportal-tree",f);var g=class extends HTMLElement{static get observedAttributes(){return["api-url","api-key","ontology","concept-id","compact","portal-url"]}constructor(){super(),this.attachShadow({mode:"open"}),this._client=null,this._concept=null}connectedCallback(){this._initClient(),this._render(),this.loadConcept()}attributeChangedCallback(e,t,o){t!==o&&(e==="api-url"||e==="api-key"?this._initClient():(e==="ontology"||e==="concept-id")&&this.loadConcept())}_initClient(){let e=this.getAttribute("api-url")||typeof window<"u"&&window.ONTOPORTAL_API_URL||"",t=this.getAttribute("api-key")||typeof window<"u"&&window.ONTOPORTAL_API_KEY||"";this._client=new c({apiURL:e,apiKey:t})}async loadConcept(){let e=this.getAttribute("ontology"),t=this.getAttribute("concept-id");if(!(!e||!t||!this._client||!this._containerEl)){this._setLoading(!0);try{this._concept=await this._client.getClass(e,t),this._renderCard(),this.dispatchEvent(new CustomEvent("ontoportal:concept-loaded",{bubbles:!0,composed:!0,detail:{concept:this._concept}}))}catch(o){this._renderError(o.message||"Failed to load concept")}finally{this._setLoading(!1)}}}_render(){this.shadowRoot.innerHTML=`
      <style>
        :host {
          display: block;
          font-family: var(--op-font-family, system-ui, -apple-system, sans-serif);
          font-size: 14px;
          color: var(--op-text-color, #1e293b);
          background: var(--op-bg-color, #ffffff);
          border: 1px solid var(--op-border-color, #e2e8f0);
          border-radius: 8px;
          box-sizing: border-box;
          box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05);
          overflow: hidden;
        }
        *, *::before, *::after {
          box-sizing: inherit;
        }
        .op-card-container {
          padding: 14px 16px;
        }
        .op-card-header {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 12px;
          margin-bottom: 8px;
        }
        .op-card-title-group {
          flex: 1;
        }
        .op-card-title {
          font-size: 16px;
          font-weight: 600;
          color: #0f172a;
          margin: 0 0 4px 0;
          line-height: 1.3;
        }
        .op-card-badge {
          display: inline-block;
          font-size: 11px;
          font-weight: 600;
          padding: 2px 8px;
          border-radius: 9999px;
          background: #ecfdf5;
          color: #065f46;
          border: 1px solid #a7f3d0;
        }
        .op-card-uri-row {
          display: flex;
          align-items: center;
          gap: 6px;
          font-size: 12px;
          color: #64748b;
          margin-bottom: 12px;
          word-break: break-all;
        }
        .op-card-uri {
          font-family: ui-monospace, SFMono-Regular, monospace;
          background: #f8fafc;
          padding: 2px 6px;
          border-radius: 4px;
          border: 1px solid #f1f5f9;
        }
        .op-copy-btn {
          background: none;
          border: 1px solid #cbd5e1;
          border-radius: 4px;
          padding: 2px 6px;
          font-size: 11px;
          cursor: pointer;
          color: #475569;
          transition: all 0.1s ease;
        }
        .op-copy-btn:hover {
          background: #f1f5f9;
          color: #0f172a;
        }
        .op-card-section {
          margin-bottom: 10px;
        }
        .op-section-label {
          font-size: 11px;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: #94a3b8;
          margin-bottom: 4px;
        }
        .op-section-content {
          font-size: 13px;
          color: #334155;
          line-height: 1.5;
        }
        .op-synonyms-list {
          display: flex;
          flex-wrap: wrap;
          gap: 4px;
          margin: 0;
          padding: 0;
          list-style: none;
        }
        .op-synonym-tag {
          font-size: 12px;
          background: #f1f5f9;
          color: #475569;
          padding: 2px 8px;
          border-radius: 4px;
        }
        .op-card-footer {
          margin-top: 14px;
          padding-top: 10px;
          border-top: 1px solid #f1f5f9;
          display: flex;
          align-items: center;
          justify-content: flex-end;
        }
        .op-portal-link {
          font-size: 12px;
          font-weight: 500;
          color: #1a7f5a;
          text-decoration: none;
          display: inline-flex;
          align-items: center;
          gap: 4px;
        }
        .op-portal-link:hover {
          text-decoration: underline;
        }
        .op-loading, .op-error {
          padding: 20px;
          text-align: center;
          color: #64748b;
        }
        .op-error {
          color: #dc2626;
        }
      </style>
      <div class="op-card-container">
        <div class="op-loading">Select or specify a concept to display...</div>
      </div>
    `,this._containerEl=this.shadowRoot.querySelector(".op-card-container")}_setLoading(e){!this._containerEl||e&&(this._containerEl.innerHTML='<div class="op-loading">Loading concept details...</div>')}_renderError(e){!this._containerEl||(this._containerEl.innerHTML=`<div class="op-error">${e}</div>`)}_renderCard(){if(!this._concept)return;let e=this.getAttribute("ontology")||"",t=this._concept.prefLabel||this._concept.name||this._concept["@id"]||"Unnamed Concept",o=this._concept["@id"]||this._concept.id||"",i=this._concept.definition||[],s=this._concept.synonym||[],r=`${this.getAttribute("portal-url")||(typeof window<"u"?window.location.origin:"")}/ontologies/${encodeURIComponent(e)}?p=classes&conceptid=${encodeURIComponent(o)}`,a=Array.isArray(i)&&i.length>0?i.map(_=>`<p class="op-section-content">${b(_)}</p>`).join(""):typeof i=="string"&&i.trim()?`<p class="op-section-content">${b(i)}</p>`:'<p class="op-section-content" style="color:#94a3b8; font-style:italic;">No definition provided</p>',p=Array.isArray(s)?s:typeof s=="string"?s.split(","):[],m=p.length>0?`<div class="op-card-section">
           <div class="op-section-label">Synonyms</div>
           <ul class="op-synonyms-list">
             ${p.slice(0,8).map(_=>`<li class="op-synonym-tag">${b(_.trim())}</li>`).join("")}
             ${p.length>8?`<li class="op-synonym-tag">+${p.length-8} more</li>`:""}
           </ul>
         </div>`:"";this._containerEl.innerHTML=`
      <div class="op-card-header">
        <div class="op-card-title-group">
          <h3 class="op-card-title">${b(t)}</h3>
          <div class="op-card-uri-row">
            <span class="op-card-uri">${b(o)}</span>
            <button type="button" class="op-copy-btn" id="op-copy-uri" aria-label="Copy URI">Copy</button>
          </div>
        </div>
        ${e?`<span class="op-card-badge">${b(e)}</span>`:""}
      </div>

      <div class="op-card-section">
        <div class="op-section-label">Definition</div>
        ${a}
      </div>

      ${m}

      <div class="op-card-footer">
        <a href="${r}" target="_blank" rel="noopener noreferrer" class="op-portal-link">
          View in Portal &rarr;
        </a>
      </div>
    `;let d=this._containerEl.querySelector("#op-copy-uri");d&&d.addEventListener("click",async()=>{try{await navigator.clipboard.writeText(o),d.textContent="Copied!",setTimeout(()=>d.textContent="Copy",1500)}catch{d.textContent="Failed"}})}};function b(l){return l?String(l).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;"):""}typeof customElements<"u"&&!customElements.get("ontoportal-concept-card")&&customElements.define("ontoportal-concept-card",g);typeof customElements<"u"&&(customElements.get("ontoportal-autocomplete")||customElements.define("ontoportal-autocomplete",u),customElements.get("ontoportal-tree")||customElements.define("ontoportal-tree",f),customElements.get("ontoportal-concept-card")||customElements.define("ontoportal-concept-card",g));typeof window<"u"&&(window.OntoPortal=window.OntoPortal||{},window.OntoPortal.Client=c,window.OntoPortal.Error=h,window.OntoPortal.Autocomplete=u,window.OntoPortal.Tree=f,window.OntoPortal.ConceptCard=g);})();
//# sourceMappingURL=ontoportal-widgets.js.map
