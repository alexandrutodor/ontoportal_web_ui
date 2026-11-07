import { Controller } from "@hotwired/stimulus"
import { FairScoreChartContainer, FairScoreCriteriaBar } from "../mixins/useFairScore";
// Connects to data-controller="fair-score-landscape"
export default class extends Controller {
  connect(){
    // One container and chart per mount; update() refreshes their data in place.
    this.fairCriteriaBars = new FairScoreCriteriaBar('ont-fair-scores-criteria-bars-canvas')
    this.fairContainer = new FairScoreChartContainer('fair-score-charts-container' , [this.fairCriteriaBars])
    this.fairContainer.getFairScoreData("all")
  }

  disconnect(){
    this.fairCriteriaBars?.chart?.destroy()
    this.fairContainer?.fairMsgErr.remove()
  }

  update(event){
    event.preventDefault()
    let ontologies = Array.from(event.target.selectedOptions || [], (option) => option.value)
    this.fairContainer.getFairScoreData(ontologies.length > 0 ? ontologies.join(',') : "all")
  }
}
