#include <string>
#include <vector>
#include <map>

namespace app {

int globalConfig = 42;
static int internalState = 0;
const std::string kAppName = "demo";

class Widget {
public:
    int width;
    std::string title;
    static int instanceCount;
private:
    int secretId;
    std::vector<int> data;
protected:
    bool dirty = false;

public:
    Widget(int w) : width(w) {
        int localTemp = w * 2;
        std::map<std::string, int> lookup;
    }
    void resize(int newWidth);
};

struct Vec3 {
    double x, y, z;
};

void freeFunction() {
    int counter = 0;
    auto handler = [](int n) { return n + 1; };
    std::vector<int> values = {1, 2, 3};
    const char *label = "tmp";
}

} // namespace app
