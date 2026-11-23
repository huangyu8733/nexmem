package gateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
)

// schemaNode 是契约中使用到的 JSON Schema 子集。
// 仅支持 type / required / properties / items / enum / minimum / maximum，
// 足以覆盖参数校验，避免为此引入第三方 schema 库。
type schemaNode struct {
	Type       string                `json:"type"`
	Required   []string              `json:"required,omitempty"`
	Properties map[string]schemaNode `json:"properties,omitempty"`
	Items      *schemaNode           `json:"items,omitempty"`
	Enum       []json.RawMessage     `json:"enum,omitempty"`
	Minimum    *float64              `json:"minimum,omitempty"`
	Maximum    *float64              `json:"maximum,omitempty"`
}

func parseSchema(raw json.RawMessage) (schemaNode, error) {
	var n schemaNode
	if len(bytes.TrimSpace(raw)) == 0 {
		return n, errors.New("schema 为空")
	}
	if err := json.Unmarshal(raw, &n); err != nil {
		return n, fmt.Errorf("schema 不是合法 JSON: %w", err)
	}
	return n, nil
}

// validateSchemaNode 在注册方法时校验 schema 本身是否合法，避免运行期才发现。
func validateSchemaNode(n schemaNode, path string) error {
	switch n.Type {
	case "object":
		for name, prop := range n.Properties {
			if err := validateSchemaNode(prop, path+"."+name); err != nil {
				return err
			}
		}
	case "array":
		if n.Items != nil {
			return validateSchemaNode(*n.Items, path+"[]")
		}
	case "string", "integer", "number", "boolean":
	default:
		return fmt.Errorf("%s 的 type %q 不受支持", path, n.Type)
	}
	return nil
}

// validateParams 校验 params 是否满足 schema；空 params 与 null 对 object 视为 {}。
func validateParams(schema, params json.RawMessage) error {
	def, err := parseSchema(schema)
	if err != nil {
		return err
	}
	if def.Type != "object" {
		return errors.New("params schema 顶层必须是 object")
	}
	trimmed := bytes.TrimSpace(params)
	if len(trimmed) == 0 || isJSONNull(trimmed) {
		trimmed = []byte("{}")
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &obj); err != nil {
		return errors.New("params 必须是 JSON 对象")
	}
	return def.validateObject(obj, "params")
}

func (n schemaNode) validateObject(obj map[string]json.RawMessage, path string) error {
	for _, name := range n.Required {
		v, ok := obj[name]
		if !ok || isJSONNull(v) {
			return fmt.Errorf("缺少必填参数 %s", name)
		}
	}
	for name, prop := range n.Properties {
		v, ok := obj[name]
		if !ok || isJSONNull(v) {
			continue
		}
		if err := prop.validate(v, path+"."+name); err != nil {
			return err
		}
	}
	return nil
}

func (n schemaNode) validate(raw json.RawMessage, path string) error {
	switch n.Type {
	case "string":
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return fmt.Errorf("%s 必须是字符串", path)
		}
	case "boolean":
		var b bool
		if err := json.Unmarshal(raw, &b); err != nil {
			return fmt.Errorf("%s 必须是布尔值", path)
		}
	case "integer":
		num, err := decodeNumber(raw)
		if err != nil {
			return fmt.Errorf("%s 必须是整数", path)
		}
		if _, err := num.Int64(); err != nil {
			return fmt.Errorf("%s 必须是整数", path)
		}
		if err := n.checkRange(num, path); err != nil {
			return err
		}
	case "number":
		num, err := decodeNumber(raw)
		if err != nil {
			return fmt.Errorf("%s 必须是数字", path)
		}
		if err := n.checkRange(num, path); err != nil {
			return err
		}
	case "array":
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			return fmt.Errorf("%s 必须是数组", path)
		}
		if n.Items != nil {
			for i, item := range items {
				if err := n.Items.validate(item, fmt.Sprintf("%s[%d]", path, i)); err != nil {
					return err
				}
			}
		}
	case "object":
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(raw, &obj); err != nil {
			return fmt.Errorf("%s 必须是对象", path)
		}
		if err := n.validateObject(obj, path); err != nil {
			return err
		}
	default:
		return fmt.Errorf("%s 的 type %q 不受支持", path, n.Type)
	}
	return n.checkEnum(raw, path)
}

func (n schemaNode) checkRange(num json.Number, path string) error {
	f, err := num.Float64()
	if err != nil {
		return fmt.Errorf("%s 必须是数字", path)
	}
	if n.Minimum != nil && f < *n.Minimum {
		return fmt.Errorf("%s 不能小于 %v", path, *n.Minimum)
	}
	if n.Maximum != nil && f > *n.Maximum {
		return fmt.Errorf("%s 不能大于 %v", path, *n.Maximum)
	}
	return nil
}

func (n schemaNode) checkEnum(raw json.RawMessage, path string) error {
	if len(n.Enum) == 0 {
		return nil
	}
	got, err := decodeAny(raw)
	if err != nil {
		return fmt.Errorf("%s 不是合法 JSON", path)
	}
	for _, allowed := range n.Enum {
		want, err := decodeAny(allowed)
		if err != nil {
			continue
		}
		if reflect.DeepEqual(got, want) {
			return nil
		}
	}
	return fmt.Errorf("%s 取值不在枚举范围内", path)
}

func decodeNumber(raw json.RawMessage) (json.Number, error) {
	v, err := decodeAny(raw)
	if err != nil {
		return "", err
	}
	num, ok := v.(json.Number)
	if !ok {
		return "", errors.New("不是数字")
	}
	return num, nil
}

func decodeAny(raw json.RawMessage) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return v, nil
}

func isJSONNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}
