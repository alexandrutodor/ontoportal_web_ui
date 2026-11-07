import {Controller} from "@hotwired/stimulus"
import {useBioportalAutoComplete} from "../mixins/useBioportalAutoComplete";

// Connects to data-controller="form-auto-complete"
export default class extends Controller {
    static values = {
        ontologyId: String,
        targetProperty: String,
        includeDefinition: Boolean
    }

    connect() {
        if (this.ontologyIdValue === "all") {
            this.ontologyIdValue = "";
        }


        this.extra_params = {
            target_property: this.targetPropertyValue,
            id: this.ontologyIdValue
        };

        let result_width = 450;


        // Add space for ontology name
        if (this.includeDefinitionValue) {
            result_width += 200;
        }
        jQuery(document).ready(() => {
            useBioportalAutoComplete(this.element, BP_INTERNAL_SEARCH_SERVER + "/search/json_search/", {
                extraParams: this.extra_params,
                lineSeparator: "~!~",
                matchSubset: 0,
                mustMatch: true,
                sortRestuls: false,
                minChars: 3,
                maxItemsToShow: 20,
                cacheLength: -1,
                width: result_width,
                onItemSelect: this.onSelect.bind(this),
                formatItem: this.formatItem.bind(this)
            })
        })

        let html = "";

        const inputName = jQuery(this.element).attr('name');
        if (document.getElementById(inputName + "_bioportal_concept_id") == null)
            html += `<input type='hidden' name='${inputName}_bioportal_concept_id' id='${inputName}_bioportal_concept_id'>`;

        if (document.getElementById(inputName + "_bioportal_ontology_id") == null)
            html += `<input type='hidden' name='${inputName}_bioportal_ontology_id' id='${inputName}_bioportal_ontology_id'>`;

        if (document.getElementById(inputName + "_bioportal_full_id") == null)
            html += `<input type='hidden' name='${inputName}_bioportal_full_id' id='${inputName}_bioportal_full_id'>`;

        if (document.getElementById(inputName + "_bioportal_preferred_name") == null)
            html += `<input type='hidden' name='${inputName}_bioportal_preferred_name' id='${inputName}_bioportal_preferred_name'>`;

        jQuery(this.element).after(html);
    }

    formatItem(row) {
        if (!row || row[0] == null) return "";

        const input = this.element;
        const specials = /[.*+?^${}()|[\]\\]/g;
        const rawVal = jQuery(input).val() ? jQuery(input).val().trim() : "";
        const keywords = rawVal ? rawVal.replace(specials, "\\$&").split(/\s+/).filter(Boolean).join('|') : "";
        const regex = keywords ? new RegExp('(' + keywords + ')', 'gi') : null;
        let result = "";
        const ontology_id = this.ontologyIdValue;
        const isAll = (ontology_id === "all" || ontology_id === "");
        let class_name_width = "350px";

        const BP_include_definitions = this.includeDefinitionValue;

        // Set wider class name column
        if (BP_include_definitions) {
            class_name_width = "150px";
        } else if (isAll) {
            class_name_width = "320px";
        }

        const decodeDef = (raw) => {
            if (raw == null) return "";
            const str = String(raw).replace(/\+/g, " ");
            try {
                return decodeURIComponent(str);
            } catch {
                return str;
            }
        };

        const buildClassDiv = () => {
            const classDiv = document.createElement("div");
            classDiv.className = "result_class";
            classDiv.style.width = class_name_width;
            const text = String(row[0]);
            if (!regex) {
                classDiv.appendChild(document.createTextNode(text));
            } else {
                const parts = text.split(regex);
                for (let i = 0; i < parts.length; i++) {
                    if (!parts[i]) continue;
                    if (i % 2 === 1) {
                        const b = document.createElement("b");
                        const span = document.createElement("span");
                        span.className = "result_class_highlight";
                        span.textContent = parts[i];
                        b.appendChild(span);
                        classDiv.appendChild(b);
                    } else {
                        classDiv.appendChild(document.createTextNode(parts[i]));
                    }
                }
            }
            return classDiv.outerHTML;
        };

        const result_type = (row[2] != null) ? String(row[2]) : "";

        // row[7] is the ontology_id, only included when searching multiple ontologies
        if (!isAll) {
            const result_def = row[7];

            if (BP_include_definitions) {
                const defDiv = document.createElement("div");
                defDiv.className = "result_definition";
                defDiv.innerHTML = this.#truncateText(decodeDef(result_def), 75);
                result += defDiv.outerHTML;
            }

            result += buildClassDiv();

            const typeDiv = document.createElement("div");
            typeDiv.className = "result_type";
            typeDiv.style.overflow = "hidden";
            typeDiv.textContent = result_type;
            result += typeDiv.outerHTML;
        } else {
            // Results
            const result_ont = (row[7] != null) ? String(row[7]) : "";
            const result_def = row[9];

            result += buildClassDiv();

            if (BP_include_definitions) {
                const defDiv = document.createElement("div");
                defDiv.className = "result_definition";
                defDiv.innerHTML = this.#truncateText(decodeDef(result_def), 75);
                result += defDiv.outerHTML;
            }

            const ontWrapper = document.createElement("div");
            ontWrapper.appendChild(document.createTextNode(" "));

            const typeDiv = document.createElement("div");
            typeDiv.className = "result_type";
            typeDiv.textContent = result_type;
            ontWrapper.appendChild(typeDiv);

            const ontDiv = document.createElement("div");
            ontDiv.className = "result_ontology";
            ontDiv.style.overflow = "hidden";
            ontDiv.innerHTML = this.#truncateText(result_ont, 35);
            ontWrapper.appendChild(ontDiv);

            result += ontWrapper.outerHTML;
        }
        return result;
    }


    onSelect(li) {
        const input = this.element;
        switch (this.targetPropertyValue) {
            case "uri":
                jQuery(input).val(li.extra[3])
                break;
            case "shortid":
                jQuery(input).val(li.extra[0])
                break;
            case "name":
                jQuery(input).val(li.extra[4])
                break;
        }

        const input_name = jQuery(input).attr('name')
        jQuery(`input[name="${input_name}_bioportal_concept_id"]`).val(li.extra[0]);
        jQuery(`input[name="${input_name}_bioportal_ontology_id"]`).val(li.extra[2]);
        jQuery(`input[name="${input_name}_bioportal_full_id"]`).val(li.extra[3]);
        jQuery(`input[name="${input_name}_bioportal_preferred_name"]`).val(li.extra[4]);
        this.#emitOnSelect()
    }

    #emitOnSelect() {
        this.element.dispatchEvent(new Event('selected'))
    }


    #truncateText(text, max_length) {
        if (text == null) return "";
        let str = String(text);

        if (typeof max_length === 'undefined' || max_length === "") {
            max_length = 70;
        }

        const more = '...';

        if (jQuery.trim(str).length <= max_length) {
            const div = document.createElement("div");
            div.textContent = str;
            return div.innerHTML;
        }

        str = str.replace(/^ /, '');

        const container = document.createElement("div");
        container.appendChild(document.createTextNode(str.slice(0, max_length)));

        const expandSpan = document.createElement("span");
        expandSpan.className = "expand_icon";
        const b = document.createElement("b");
        b.textContent = more;
        expandSpan.appendChild(b);
        container.appendChild(expandSpan);

        const longSpan = document.createElement("span");
        longSpan.className = "long_text";
        longSpan.textContent = str.slice(max_length);
        container.appendChild(longSpan);

        return container.innerHTML;
    }
}
