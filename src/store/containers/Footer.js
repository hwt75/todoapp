import { connect } from "react-redux";
import { saveTheme } from "../action/changeThemeActions";
import Footer from "../../components/layout/Footer";

const mapDispatchToProps = dispatch => ({
  dispatch,
  saveColorTheme: color => dispatch(saveTheme(color))
});

function mapStateToProps(state) {
  return {
    themeColor: state.color
  };
}

export default connect(
  mapStateToProps,
  mapDispatchToProps
)(Footer);
