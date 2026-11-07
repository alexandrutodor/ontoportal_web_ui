function isSameOrigin(url) {
    if (!url || typeof url !== 'string') return false;
    if (typeof window === 'undefined' || !window.location || !window.location.href) {
        return url.startsWith('/') && !url.startsWith('//');
    }
    try {
        const parsed = new URL(url, window.location.href);
        return parsed.origin === window.location.origin;
    } catch (e) {
        return false;
    }
}

export function useBioportalAutoComplete(element, endpointUrl, options) {
    var opts = Object.assign({}, options);
    if (!opts.response && isSameOrigin(endpointUrl)) {
        opts.response = 'rows';
    }
    jQuery(element).bioportal_autocomplete(endpointUrl, opts);
}
