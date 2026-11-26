// Internal REST URLs for the UA build. Keep the sort values in their input order.
window.kohaUaApiGetUrl = function (endpoint) {
    let url;
    try {
        url = new URL(endpoint, window.location.href);
    } catch {
        return endpoint;
    }
    if (
        url.origin !== window.location.origin ||
        !url.pathname.startsWith("/api/v1/")
    ) {
        return endpoint;
    }

    let changed = false;
    for (const suffix of ["", "[]"]) {
        const canonical = "_order_by" + suffix;
        const values = url.searchParams.getAll(canonical);
        if (!values.length) continue;

        const alias = "_ordnung_by" + suffix;
        url.searchParams.delete(canonical);
        url.searchParams.delete(alias);
        for (const value of values) {
            url.searchParams.append(alias, value);
        }
        changed = true;
    }

    return changed ? url.href : endpoint;
};
