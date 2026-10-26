// Update check tags (runtime/ui/update_tags.h): their order and labels. No game, no network.
// Build + run: clang++ -std=c++17 -O1 tools/test_update_tags.cpp -o build/test-update-tags && build/test-update-tags
#include <stdio.h>

#include "../runtime/ui/update_tags.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
    // oldest to newest; equal ranks share a group
    const char *order[][2] = {
        {"beta_1", "v0.1.0"}, {"beta_4", NULL}, {"beta_5", "v0.5.0"}, {"beta_5.1", "v0.5.1"}, {"beta_5.2", NULL},
        {"beta_5.3", "v0.5.3"}, {"beta_5.4", NULL}, {"v0.6.0", "beta_6"}, {"v0.6.1", "beta_6.1"}, {"v0.6.12", NULL},
        {"v0.7.0", NULL}, {"v0.99.0", NULL}, {"v1.0.0", NULL}, {"v1.0.1", NULL}, {"v1.1.0", NULL}, {"v2.0.0", NULL},
    };
    int n = sizeof order / sizeof *order;
    for (int i = 0; i < n; i++) {
        long long r = tag_rank(order[i][0]);
        CHECK(r > 0, "%s ranks (%lld)", order[i][0], r);
        if (order[i][1]) CHECK(tag_rank(order[i][1]) == r, "%s == %s", order[i][1], order[i][0]);
        for (int j = i + 1; j < n; j++)
            CHECK(tag_rank(order[j][0]) > r, "%s > %s", order[j][0], order[i][0]);
    }
    const char *never[] = {"alpha_3", "test-388-grass", "beta_0", "beta_5.0", "v0.0.1", "v1.0", "v0.6.0-rc1", "beta_5.3x",
                           "ci-test-1", "", "v", "beta_"};
    for (const char *t : never) CHECK(tag_rank(t) == -1, "'%s' is not a release (%lld)", t, tag_rank(t));

    const char *labels[][3] = {  // tag, label, with the word
        {"beta_5", "Beta 5", "Beta 5"},
        {"beta_5.3", "Beta 5 Hotfix 3", "Beta 5 Hotfix 3"},
        {"v0.6.0", "Beta 6", "Beta 6"},
        {"v0.6.1", "Beta 6.1", "Beta 6.1"},
        {"v0.10.2", "Beta 10.2", "Beta 10.2"},
        {"v1.0.0", "1.0.0", "Version 1.0.0"},
        {"v1.2.3", "1.2.3", "Version 1.2.3"},
        {"test-foo", "Test build foo", "Test build foo"},
    };
    for (auto &l : labels) {
        std::string a = tag_label(l[0], false), b = tag_label(l[0], true);
        CHECK(a == l[1], "%s -> '%s', want '%s'", l[0], a.c_str(), l[1]);
        CHECK(b == l[2], "%s (with word) -> '%s', want '%s'", l[0], b.c_str(), l[2]);
    }
    if (fails) { printf("%d failed\n", fails); return 1; }
    printf("update tags: all passed\n");
    return 0;
}
