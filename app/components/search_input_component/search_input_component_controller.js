import {Controller} from "@hotwired/stimulus"
import useAjax from "../../javascript/mixins/useAjax";
import debounce from 'debounce'

// Connects to data-controller="search-input"
export default class extends Controller {
    static targets = ["input", "dropDown", "actionLink", "template", "button", "loader"]
    static values = {
        items: Array,
        ajaxUrl: String,
        itemLinkBase: String,
        idKey: String,
        cache: {type: Boolean, default: true},
        selectedItem: Number,
        searchEndpoint: {type: String, default: '/search'},
        displayAll: Boolean
    }

    connect() {
        this.input = this.inputTarget
        this.dropDown = this.dropDownTarget
        this.actionLinks = this.actionLinkTargets
        this.items = this.itemsValue
        this.search = debounce(this.search.bind(this), 100);
    }

    search() {
        this.selectedItemValue = 0
        this.loaderTarget.classList.remove("d-none")
        this.buttonTarget.classList.add("d-none")
        this.searchInput()
    }

    searchInput() {
        this.#fetchItems()
    }

    prevent(event){
        event.preventDefault();
    }
    blur() {
        this.dropDown.style.display = "none";
        this.input.classList.remove("home-dropdown-active");
    }
    arrow_up(){
        if (this.selectedItemValue > 1){
            this.selectedItemValue--
            this.dropDownTarget.querySelectorAll('.search-content')[this.selectedItemValue-1].style.backgroundColor = "rgba(0, 0, 0, 0.03)";
            this.dropDownTarget.querySelectorAll('.search-content')[this.selectedItemValue].style.background = 'white'
        }
    }
    arrow_down(){
        if(this.selectedItemValue<this.dropDownTarget.querySelectorAll('.search-content').length){
            this.selectedItemValue++
        }
        this.dropDownTarget.querySelectorAll('.search-content')[this.selectedItemValue-1].style.backgroundColor = "rgba(0, 0, 0, 0.03)";
        if(this.selectedItemValue > 1){
            this.dropDownTarget.querySelectorAll('.search-content')[this.selectedItemValue-2].style.background = 'white'
        } 
    }
    enter_key(){
        if(this.inputTarget.value != ''){
            let results = this.dropDownTarget.querySelectorAll('.search-content')
            if(this.selectedItemValue === 0 || this.dropDownTarget.style.display === 'none'){
                results[results.length - 2].click()
            } else {
                results[this.selectedItemValue-1].click()
            }
        }        
    }
    #inputValue() {
        return this.input.value.trim()
    }

    #useCache() {
        return this.cacheValue
    }


    #fetchItems() {
        if (this.items.length !== 0 && this.#useCache()) {
            this.#renderLines()
        } else {
            useAjax({
                type: "GET",
                url: this.ajaxUrlValue + encodeURIComponent(this.#inputValue()),
                dataType: "json",
                success: (data) => {
                    this.items = data.map(x => { return {...x, link: (this.itemLinkBaseValue + x[this.idKeyValue])}} )
                    this.#renderLines()
                },
                error: () => {
                    console.log("error")
                    //TODO show errors
                }
            })
        }
    }

    #baseUri() {
        return (document.location && document.location.protocol && document.location.protocol.startsWith('http'))
            ? document.location.href
            : 'http://localhost';
    }

    #renderLines() {
        this.loaderTarget.classList.add("d-none")
        this.buttonTarget.classList.remove("d-none")
        const inputValue = this.#inputValue();
        let results_list = []
        if (inputValue.length > 0) {
            const base = this.#baseUri();
            const origin = new URL(base).origin;
            const searchUrl = new URL(this.searchEndpointValue || '/search', base);
            searchUrl.searchParams.set("q", inputValue);
            this.buttonTarget.href = (searchUrl.origin === origin)
                ? (searchUrl.pathname + searchUrl.search + searchUrl.hash)
                : searchUrl.href;

            this.actionLinks.forEach(action => {
                const content = action.querySelector('p');
                if (content) {
                    content.textContent = inputValue;
                }
                const rawHref = action.getAttribute('href') || action.href || '';
                const currentURL = new URL(rawHref, base);
                const targetKey = currentURL.searchParams.has('query')
                    ? 'query'
                    : (currentURL.searchParams.has('search')
                        ? 'search'
                        : (currentURL.searchParams.keys().next().value || 'q'));
                currentURL.searchParams.set(targetKey, inputValue);
                action.href = (currentURL.origin === origin)
                    ? (currentURL.pathname + currentURL.search + currentURL.hash)
                    : currentURL.href;
            });

            this.dropDown.replaceChildren();
            let breaker = 0;
            for (let i = 0; i < this.items.length; i++) {
                if (!this.displayAllValue && breaker === 4) {
                    break;
                }
                // Get the current item from the ontologies array
                const item = this.items[i];

                let text = Object.values(item).reduce((acc, value) => acc + (value != null ? value : ""), "");
                
                // Check if the item contains the substring
                if (!this.cacheValue || text.toLowerCase().includes(inputValue.toLowerCase())) {
                    results_list.push(item);
                    breaker = breaker + 1;
                }
            }

            results_list.forEach((item) => {
                let link = this.#renderLine(item);
                if (link) {
                    this.dropDown.appendChild(link);
                }
            });

            this.actionLinks.forEach(x => this.dropDown.appendChild(x));
            this.dropDown.style.display = "block";

            this.input.classList.add("home-dropdown-active");


        } else {
            this.dropDown.style.display = "none";
            this.input.classList.remove("home-dropdown-active");
        }

    }

    #isSafeHref(url) {
        if (typeof url !== 'string') return false;
        const trimmed = url.trim();
        if (!trimmed || /[\x00-\x1F\x7F]/.test(trimmed)) return false;
        try {
            const parsed = new URL(trimmed, this.#baseUri());
            return parsed.protocol === 'http:' || parsed.protocol === 'https:';
        } catch {
            return false;
        }
    }

    #renderLine(item) {
        const template = this.templateTarget.content;
        if (!template || !template.firstElementChild) return null;
        const element = template.firstElementChild.cloneNode(true);

        const dict = {};
        for (const [rawKey, rawVal] of Object.entries(item)) {
            if (rawKey == null) continue;
            const key = String(rawKey).toUpperCase();
            let val = rawVal != null ? String(rawVal) : '';
            if (key === 'TYPE') {
                const segments = val.split('/').filter(Boolean);
                val = segments.length > 0 ? segments[segments.length - 1] : val;
            } else if (key === 'ACRONYM') {
                val = val ? `(${val})` : '';
            } else if (key === 'IDENTIFIERS') {
                val = val ? `- ${val}` : '';
            }
            dict[key] = val;
        }

        const itemLink = item.link != null ? String(item.link) : (item.LINK != null ? String(item.LINK) : '');
        const anchors = (element.matches('a') ? [element] : []).concat(Array.from(element.querySelectorAll('a')));
        anchors.forEach(a => {
            const rawHref = a.getAttribute('href');
            if (rawHref && /\bLINK\b/i.test(rawHref)) {
                const candidate = (rawHref === 'LINK') ? itemLink : rawHref.replace(/\bLINK\b/gi, itemLink);
                if (this.#isSafeHref(candidate)) {
                    a.setAttribute('href', candidate);
                } else {
                    a.removeAttribute('href');
                }
            }
        });

        const keys = Object.keys(dict).filter(k => k.length > 0);
        if (keys.length > 0) {
            keys.sort((a, b) => b.length - a.length);
            const pattern = new RegExp('\\b(' + keys.map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')\\b', 'gi');
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
            const textNodes = [];
            while (walker.nextNode()) {
                textNodes.push(walker.currentNode);
            }
            for (const node of textNodes) {
                const originalText = node.nodeValue;
                if (!originalText) continue;
                pattern.lastIndex = 0;
                if (pattern.test(originalText)) {
                    pattern.lastIndex = 0;
                    node.nodeValue = originalText.replace(pattern, (match) => {
                        const upper = match.toUpperCase();
                        return Object.prototype.hasOwnProperty.call(dict, upper) ? dict[upper] : match;
                    });
                }
            }
        }

        return element;
    }
}
