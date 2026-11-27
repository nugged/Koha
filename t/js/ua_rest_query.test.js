const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const asset = join(
    __dirname,
    "../../koha-tmpl/intranet-tmpl/prog/js/ua-rest-query.js"
);
const window = { location: new URL("https://koha.example/cgi-bin/koha/mainpage.pl") };
vm.runInNewContext(readFileSync(asset, "utf8"), { window, URL });
const requestUrl = window.kohaUaApiGetUrl;

test("maps Koha REST sort keys and preserves search terms and pagination", () => {
    const filters = JSON.stringify({ name: "luke", title: "like" });
    const original = new URL("/api/v1/patrons", window.location);
    original.searchParams.set("q", filters);
    original.searchParams.set("_page", "2");
    original.searchParams.set("_order_by", "+surname,-firstname");
    original.searchParams.append("_order_by[]", "+branch");
    original.searchParams.append("_order_by[]", "-cardnumber");

    const result = new URL(requestUrl(original));
    assert.equal(result.searchParams.get("_ordnung_by"), "+surname,-firstname");
    assert.deepEqual(result.searchParams.getAll("_ordnung_by[]"), [
        "+branch",
        "-cardnumber",
    ]);
    assert.equal(result.searchParams.has("_order_by"), false);
    assert.equal(result.searchParams.has("_order_by[]"), false);
    assert.equal(result.searchParams.get("q"), filters);
    assert.equal(result.searchParams.get("_page"), "2");
    assert.equal(original.searchParams.get("_order_by"), "+surname,-firstname");
});

test("leaves unrelated, cross-origin and already normalized requests untouched", () => {
    for (const url of [
        "/api/v1/libraries?_ordnung_by=name",
        "/api/v1/libraries?q=_order_by",
        "/cgi-bin/koha/mainpage.pl?_order_by=name",
        "https://other.example/api/v1/libraries?_order_by=name",
    ]) {
        assert.equal(requestUrl(url), url);
    }
});
