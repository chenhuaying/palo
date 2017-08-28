// Copyright (c) 2017, Baidu.com, Inc. All Rights Reserved

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include "exprs/json_functions.h"

#include <string>
#include <gtest/gtest.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/document.h>
#include <rapidjson/writer.h>
#include <re2/re2.h>

#include "runtime/runtime_state.h"
#include "common/object_pool.h"
#include "util/logging.h"

namespace palo {

// mock
class JsonFunctionTest : public testing::Test {
public:
    JsonFunctionTest() {
    }
};

TEST_F(JsonFunctionTest, string)
{
    std::string json_string("{\"id\":\"name\",\"age\":11,\"money\":123000.789}");
    std::string path_string("$.id");
    rapidjson::Document document1;
    rapidjson::Value* res1 = JsonFunctions::get_json_object(json_string, path_string,
                      JSON_FUN_STRING, &document1);
    ASSERT_EQ(std::string(res1->GetString()), "name");

    std::string json_string2("{\"price a\": [0,1,2],\"couponFee\":0}");
    std::string path_string2("$.price a");
    rapidjson::Document document2;
    rapidjson::Value* res2 = JsonFunctions::get_json_object(json_string2, path_string2,
                       JSON_FUN_STRING, &document2);
    rapidjson::StringBuffer buf2;
    rapidjson::Writer<rapidjson::StringBuffer> writer2(buf2);
    res2->Accept(writer2);
    ASSERT_EQ(std::string(buf2.GetString()), "[0,1,2]");

    std::string json_string3("{\"price a\": [],\"couponFee\":0}");
    std::string path_string3("$.price a");
    rapidjson::Document document3;
    rapidjson::Value* res3 = JsonFunctions::get_json_object(json_string3, path_string3,
                       JSON_FUN_STRING, &document3);
    rapidjson::StringBuffer buf3;
    rapidjson::Writer<rapidjson::StringBuffer> writer3(buf3);
    res3->Accept(writer3);
    ASSERT_EQ(std::string(buf3.GetString()), "[]");

    std::string json_string4("{\"price a\": [],\"couponFee\":null}");
    std::string path_string4("$.couponFee");
    rapidjson::Document document4;
    rapidjson::Value* res4 = JsonFunctions::get_json_object(json_string4, path_string4,
                       JSON_FUN_STRING, &document4);
    ASSERT_TRUE(res4->IsNull());

    std::string json_string5("{\"blockNames\": {}," 
        "\"seatCategories\": [{\"areas\": [{\"areaId\": 205705999,\"blockIds\": []},"
        "{\"areaId\": 205705998,\"blockIds\": []}],\"seatCategoryId\": 338937290}]}");
    std::string path_string5_1("$.blockNames");
    rapidjson::Document document5_1;
    rapidjson::Value* res5_1 = JsonFunctions::get_json_object(json_string5, path_string5_1,
                       JSON_FUN_STRING, &document5_1);
    rapidjson::StringBuffer buf5_1;
    rapidjson::Writer<rapidjson::StringBuffer> writer5_1(buf5_1);
    res5_1->Accept(writer5_1);
    ASSERT_EQ(std::string(buf5_1.GetString()), "{}");

    std::string path_string5_2("$.seatCategories.areas.blockIds");
    rapidjson::Document document5_2;
    rapidjson::Value* res5_2 = JsonFunctions::get_json_object(json_string5, path_string5_2,
                       JSON_FUN_STRING, &document5_2);
    rapidjson::StringBuffer buf5_2;
    rapidjson::Writer<rapidjson::StringBuffer> writer5_2(buf5_2);
    res5_2->Accept(writer5_2);
    ASSERT_EQ(std::string(buf5_2.GetString()), "[]");

    std::string path_string5_3("$.seatCategories.areas[0].areaId");
    rapidjson::Document document5_3;
    rapidjson::Value* res5_3 = JsonFunctions::get_json_object(json_string5, path_string5_3,
                       JSON_FUN_STRING, &document5_2);
    rapidjson::StringBuffer buf5_3;
    rapidjson::Writer<rapidjson::StringBuffer> writer5_3(buf5_3);
    res5_3->Accept(writer5_3);
    ASSERT_EQ(std::string(buf5_3.GetString()), "205705999");
}

TEST_F(JsonFunctionTest, int)
{
    std::string json_string("{\"id\":\"name\",\"age\":11,\"money\":123000.789}");
    std::string path_string("$.age");
    rapidjson::Document document;
    rapidjson::Value* res = JsonFunctions::get_json_object(json_string, path_string,
                      JSON_FUN_INT, &document);
    ASSERT_EQ(res->GetInt(), 11);

    std::string
    json_string1("{\"list\":[{\"id\":[{\"aa\":1}]},{\"id\":[{\"aa\":\"cc\"}]},"
            "{\"id\":[{\"kk\":\"cc\"}]}]}");
    std::string path_string1("$.list.id.aa[0]");
    rapidjson::Document document1;
    rapidjson::Value* res1 = JsonFunctions::get_json_object(json_string1, path_string1,
                       JSON_FUN_INT, &document1);
    ASSERT_EQ(res1->GetInt(), 1);

    std::string json_string2("[1,2,3,5,8,0]");
    std::string path_string2("$.[3]");
    rapidjson::Document document2;
    rapidjson::Value* res2 = JsonFunctions::get_json_object(json_string2, path_string2,
                       JSON_FUN_INT, &document2);
    ASSERT_EQ(res2->GetInt(), 5);

    std::string json_string3("{\"price a\": [0,1,2],\"couponFee\":0.0}");
    std::string path_string3_1("$.price a[3]");
    rapidjson::Document document3_1;
    rapidjson::Value* res3_1 = JsonFunctions::get_json_object(json_string3, path_string3_1,
                         JSON_FUN_INT, &document3_1);
    ASSERT_TRUE(res3_1->IsNull());

    std::string path_string3_2("$.couponFee");
    rapidjson::Document document3_2;
    rapidjson::Value* res3_2 = JsonFunctions::get_json_object(json_string3, path_string3_2,
                         JSON_FUN_INT, &document3_2);
    ASSERT_FALSE(res3_2->IsInt());
}

TEST_F(JsonFunctionTest, double)
{
    std::string json_string("{\"id\":\"name\",\"age\":11,\"money\":123000.789}");
    std::string path_string("$.money");
    rapidjson::Document document;
    rapidjson::Value* res = JsonFunctions::get_json_object(json_string, path_string,
                      JSON_FUN_DOUBLE, &document);
    ASSERT_EQ(res->GetDouble(), 123000.789);

    std::string path_string2("$.age");
    rapidjson::Document document2;
    rapidjson::Value* res2 = JsonFunctions::get_json_object(json_string, path_string2,
                       JSON_FUN_DOUBLE, &document2);
    ASSERT_EQ(res2->GetInt(), 11);
}

}

int main(int argc, char** argv) {
    std::string conffile = std::string(getenv("PALO_HOME")) + "/conf/be.conf";
    if (!palo::config::init(conffile.c_str(), false)) {
        fprintf(stderr, "error read config file. \n");
        return -1;
    }
    palo::init_glog("be-test");
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}

