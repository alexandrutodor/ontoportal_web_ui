import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="recommender"
export default class extends Controller {
  static targets = ['button', 'input', 'result', 'maxset', 'empty', 'ontologieschoice']

  connect(){
    if(document.querySelector('input[name="highlighted_recommendation"]:checked') !== null){
      this.handleHighlightedChange()
    }  

    let ontologies_choice = this.ontologieschoiceTarget.childNodes[1].childNodes[1]
    if(!ontologies_choice.checked){
      this.togglesets()
    }
  }
  edit(event){
    this.#toggle(this.buttonTarget)
    this.#toggle(event.currentTarget)
    this.#toggle(this.inputTarget)
    this.#toggle(this.resultTarget)
  }
  togglesets(){
    this.#toggle(this.maxsetTarget)
    this.#toggle(this.emptyTarget)
  }

  handleHighlightedChange(){
    const recommandations_area = this.resultTarget;
    if (!recommandations_area) return;

    const checkedRadio = document.querySelector('input[name="highlighted_recommendation"]:checked');
    let annotations = [];
    if (checkedRadio && checkedRadio.value) {
      try {
        const parsed = JSON.parse(checkedRadio.value);
        if (Array.isArray(parsed)) {
          annotations = parsed;
        }
      } catch (e) {
        // invalid JSON: fall back to empty array without throw or data loss
      }
    }

    const isSafeUrl = (url) => {
      if (typeof url !== 'string') return false;
      const trimmed = url.trim();
      if (!trimmed || /[\x00-\x1F\x7F]/.test(trimmed)) return false;
      if (trimmed.startsWith('//') || trimmed.startsWith('\\\\')) return false;
      try {
        const base = (typeof document !== 'undefined' && document.baseURI) ||
                     (typeof window !== 'undefined' && window.location && window.location.href) ||
                     'http://localhost/';
        const parsed = new URL(trimmed, base);
        return parsed.protocol === 'http:' || parsed.protocol === 'https:';
      } catch (e) {
        return false;
      }
    };

    const text = recommandations_area.textContent;
    const tokens = text.split(/(\s+)/);
    const fragment = document.createDocumentFragment();

    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (!token) continue;
      if (/^\s+$/.test(token)) {
        fragment.appendChild(document.createTextNode(token));
        continue;
      }
      const word = token.replace(/[.,\/#!$%\^&\*;:{}=\-_`~()]/g, '').toLowerCase();
      const foundItem = annotations.find(item => item && typeof item.text === 'string' && item.text.toLowerCase() === word);

      if (foundItem && isSafeUrl(foundItem.link)) {
        const a = document.createElement('a');
        a.setAttribute('style', 'color:var(--primary-color) !important;');
        a.setAttribute('href', foundItem.link);
        a.textContent = token;
        fragment.appendChild(a);
      } else {
        fragment.appendChild(document.createTextNode(token));
      }
    }

    recommandations_area.textContent = '';
    recommandations_area.appendChild(fragment);
  }

  handleInput(event){
    var selectedInputChoice = document.querySelector('input[name="input_type"]:checked').value;
    if (selectedInputChoice === "2"){
      const textarea = event.currentTarget
      const value = textarea.value;
      const lastCharIsSpace = event.data === ' ';
      const formattedValue = lastCharIsSpace ? value.trim() + ', ' : value;
      textarea.value = formattedValue;
    }
  }

  #toggle(element){
    element.classList.toggle('d-none')
  }
}
