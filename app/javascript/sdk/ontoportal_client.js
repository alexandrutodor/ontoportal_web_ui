/**
 * OntoPortal REST API Client (ESM)
 * Zero-dependency, type-safe client with LRU caching, timeout, and AbortSignal support.
 */

export class OntoPortalError extends Error {
  constructor(message, status = 500, details = null) {
    super(message);
    this.name = 'OntoPortalError';
    this.status = status;
    this.details = details;
  }
}

export class SimpleLRUCache {
  constructor(maxSize = 200) {
    this.maxSize = maxSize;
    this.cache = new Map();
  }

  get(key) {
    if (!this.cache.has(key)) return undefined;
    const value = this.cache.get(key);
    this.cache.delete(key);
    this.cache.set(key, value);
    return value;
  }

  set(key, value) {
    if (this.cache.has(key)) {
      this.cache.delete(key);
    } else if (this.cache.size >= this.maxSize) {
      const oldestKey = this.cache.keys().next().value;
      this.cache.delete(oldestKey);
    }
    this.cache.set(key, value);
  }

  clear() {
    this.cache.clear();
  }
}

export class OntoPortalClient {
  /**
   * @param {Object} config
   * @param {string} [config.apiURL] - Base API URL (e.g. "https://data.stage.matportal.org" or "/ajax")
   * @param {string} [config.apiKey] - API Key token
   * @param {string} [config.uiURL] - Base UI URL for link generation
   * @param {number} [config.timeout] - Request timeout in milliseconds (default: 15000)
   * @param {number} [config.cacheSize] - Max cache entries (default: 200)
   */
  constructor(config = {}) {
    this.apiURL = (config.apiURL || '').replace(/\/+$/, '');
    this.apiKey = config.apiKey || '';
    this.uiURL = (config.uiURL || '').replace(/\/+$/, '');
    this.timeout = config.timeout || 15000;
    this.cache = new SimpleLRUCache(config.cacheSize || 200);
  }

  /**
   * Build absolute URL with query parameters
   * @private
   */
  _buildURL(path, params = {}) {
    const isFullUrl = /^https?:\/\//i.test(path);
    const base = isFullUrl ? path : `${this.apiURL}${path.startsWith('/') ? path : '/' + path}`;
    const url = new URL(base, typeof window !== 'undefined' && window.location ? window.location.origin : 'http://localhost');

    // Add apiKey if provided and not already present
    if (this.apiKey && !url.searchParams.has('apikey')) {
      url.searchParams.set('apikey', this.apiKey);
    }

    Object.entries(params).forEach(([key, val]) => {
      if (val !== undefined && val !== null && val !== '') {
        url.searchParams.set(key, val);
      }
    });

    return url.toString();
  }

  /**
   * Standardized fetch wrapper with timeout, signal, and caching
   * @private
   */
  async _fetch(url, options = {}) {
    const cacheKey = url;
    if (options.useCache !== false && (!options.method || options.method === 'GET')) {
      const cached = this.cache.get(cacheKey);
      if (cached) return cached;
    }

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), options.timeout || this.timeout);

    let signal = controller.signal;
    if (options.signal) {
      options.signal.addEventListener('abort', () => controller.abort());
    }

    const headers = {
      Accept: 'application/json',
      ...(options.headers || {})
    };

    if (this.apiKey && !headers['Authorization']) {
      headers['Authorization'] = `apikey token=${this.apiKey}`;
    }

    try {
      const response = await fetch(url, {
        method: options.method || 'GET',
        headers,
        signal,
        body: options.body
      });

      clearTimeout(timeoutId);

      if (!response.ok) {
        let errMessage = `HTTP ${response.status} ${response.statusText}`;
        let details = null;
        try {
          details = await response.json();
          if (details && (details.error || details.message)) {
            errMessage = details.error || details.message;
          }
        } catch (_) {}
        throw new OntoPortalError(errMessage, response.status, details);
      }

      const data = await response.json();
      if (options.useCache !== false && (!options.method || options.method === 'GET')) {
        this.cache.set(cacheKey, data);
      }
      return data;
    } catch (err) {
      clearTimeout(timeoutId);
      if (err.name === 'AbortError') {
        throw new OntoPortalError('Request timed out or aborted', 408);
      }
      if (err instanceof OntoPortalError) {
        throw err;
      }
      throw new OntoPortalError(err.message, 500, err);
    }
  }

  /**
   * Search classes across one or multiple ontologies
   * @param {string} query - Search keyword
   * @param {Object} [options] - Options (ontologies, pagesize, page, require_exact)
   */
  async search(query, options = {}) {
    if (!query || !query.trim()) return { collection: [], page: 1, pageCount: 0 };

    const params = {
      q: query.trim(),
      ontologies: options.ontologies || '',
      pagesize: options.pageSize || options.pagesize || 25,
      page: options.page || 1,
      require_exact: options.requireExact ? 'true' : 'false',
      include: options.include || 'prefLabel,synonym,definition,obsolete,subClassOf'
    };

    const url = this._buildURL('/search', params);
    return await this._fetch(url, options);
  }

  /**
   * Get root classes for an ontology
   * @param {string} ontologyAcronym
   * @param {Object} [options]
   */
  async getRoots(ontologyAcronym, options = {}) {
    const encodedOnt = encodeURIComponent(ontologyAcronym);
    const params = {
      include: options.include || 'prefLabel,hasChildren,subClassOf,obsolete'
    };
    const url = this._buildURL(`/ontologies/${encodedOnt}/classes/roots`, params);
    return await this._fetch(url, options);
  }

  /**
   * Get children of a class
   * @param {string} ontologyAcronym
   * @param {string} classId - Full URI or CURIE
   * @param {Object} [options]
   */
  async getChildren(ontologyAcronym, classId, options = {}) {
    const encodedOnt = encodeURIComponent(ontologyAcronym);
    const encodedClass = encodeURIComponent(classId);
    const params = {
      include: options.include || 'prefLabel,hasChildren,subClassOf,obsolete'
    };
    const url = this._buildURL(`/ontologies/${encodedOnt}/classes/${encodedClass}/children`, params);
    return await this._fetch(url, options);
  }

  /**
   * Get parents of a class
   * @param {string} ontologyAcronym
   * @param {string} classId
   * @param {Object} [options]
   */
  async getParents(ontologyAcronym, classId, options = {}) {
    const encodedOnt = encodeURIComponent(ontologyAcronym);
    const encodedClass = encodeURIComponent(classId);
    const url = this._buildURL(`/ontologies/${encodedOnt}/classes/${encodedClass}/parents`);
    return await this._fetch(url, options);
  }

  /**
   * Get class details by URI
   * @param {string} ontologyAcronym
   * @param {string} classId
   * @param {Object} [options]
   */
  async getClass(ontologyAcronym, classId, options = {}) {
    const encodedOnt = encodeURIComponent(ontologyAcronym);
    const encodedClass = encodeURIComponent(classId);
    const params = {
      include: options.include || 'prefLabel,synonym,definition,properties,subClassOf,hasChildren,obsolete'
    };
    const url = this._buildURL(`/ontologies/${encodedOnt}/classes/${encodedClass}`, params);
    return await this._fetch(url, options);
  }

  /**
   * Get ontology summary metadata
   * @param {string} ontologyAcronym
   * @param {Object} [options]
   */
  async getOntology(ontologyAcronym, options = {}) {
    const encodedOnt = encodeURIComponent(ontologyAcronym);
    const url = this._buildURL(`/ontologies/${encodedOnt}`);
    return await this._fetch(url, options);
  }

  /**
   * Clear cache
   */
  clearCache() {
    this.cache.clear();
  }
}

export default OntoPortalClient;
