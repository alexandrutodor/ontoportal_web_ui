import {Controller} from "@hotwired/stimulus"
import {useBioportalAutoComplete} from "../mixins/useBioportalAutoComplete";
// Connects to data-controller="ontoportal-autocomplete"
export default class extends Controller {
    static  values = {
        objectTypes: String, default: 'class',
        ontologyAcronym: String
    }

    connect() {
        jQuery(document).ready(() => {
            useBioportalAutoComplete(this.element, "/search/json_search/" + this.ontologyAcronymValue,{
                extraParams: {objecttypes: this.objectTypesValue},
                selectFirst: true,
                lineSeparator: "~!~",
                matchSubset: 0,
                minChars: 1,
                maxItemsToShow: 25,
                onFindValue:  this.onFindValue.bind(this),
                onItemSelect:  this.onItemSelect.bind(this),
                formatItem: this.#formatItem.bind(this)
            })
        })
    }

    onFindValue(li){
        throw new Error('You have to implement the method');
    }

    onItemSelect(li){
        throw new Error('You have to implement the method');
    }

    #formatItem(row) {
        if (!row || row[0] == null) return "";

        let specials = /[.*+?^${}()|[\]\\]/g;
        let rawVal = (this.element && this.element.value) ? this.element.value.trim() : "";
        let keywords = rawVal ? rawVal.replace(specials, "\\$&").split(/\s+/).filter(Boolean).join('|') : "";
        let regex = keywords ? new RegExp('(' + keywords + ')', 'gi') : null;

        let label = String(row[0]);

        if (regex && label.match(regex) == null && row[6]) {
            let contents = String(row[6]).split("\t");
            let synonym = contents[0] || "";
            if (synonym) {
                let synonyms = synonym.split(";");
                let matchSynonym = jQuery.grep(synonyms, function (e) {
                    return regex ? e.match(regex) != null : false;
                });
                if (matchSynonym.length !== 0) {
                    label = label + " (synonym: " + matchSynonym.join(" ") + ")";
                }
            }
        }

        // Cleanup obsolete class tag before markup for search keywords.
        let isObsolete = false;
        if (label.indexOf("[obsolete]") !== -1) {
            label = label.replace("[obsolete]", "");
            isObsolete = true;
        }

        let wrapper = document.createElement("span");
        if (isObsolete) {
            wrapper.className = "obsolete_class";
            wrapper.title = "obsolete class";
        }

        if (!regex) {
            wrapper.appendChild(document.createTextNode(label));
        } else {
            let parts = label.split(regex);
            for (let i = 0; i < parts.length; i++) {
                if (!parts[i]) continue;
                if (i % 2 === 1) {
                    let b = document.createElement("b");
                    let span = document.createElement("span");
                    span.setAttribute("style", "color:#006600;");
                    span.textContent = parts[i];
                    b.appendChild(span);
                    wrapper.appendChild(b);
                } else {
                    wrapper.appendChild(document.createTextNode(parts[i]));
                }
            }
        }

        if (typeof row[2] !== "undefined" && row[2] !== null && String(row[2]) !== "") {
            wrapper.appendChild(document.createTextNode(" "));
            let typeSpan = document.createElement("span");
            typeSpan.setAttribute("style", "font-size:9px;color:blue;");
            typeSpan.textContent = "(" + String(row[2]) + ")";
            wrapper.appendChild(typeSpan);
        }

        return isObsolete ? wrapper.outerHTML : wrapper.innerHTML;
    }


}
